------------------------------------------------------------------------
-- Readycheck_Extras - First-Run Setup Wizard
-- Builds RC.SetupWizard: a step-array onboarding wizard shown once per
-- account. Core_Scan lazy-loads this addon and calls Wizard:Open() only
-- after checking every character profile's setupWizard.completed flag.
-- Each step's checkboxes write straight into RC.db and save immediately -
-- there is no separate commit step, so closing mid-wizard keeps whatever
-- was already toggled. Only lastStep is persisted per step; "completed"
-- is set by Finish on the last step and by Skip setup. Finish then opens
-- the settings window and starts the tour of it (Tutorial.lua).
-- Steps that do not apply to this character (Battle Shout off a warrior)
-- are left out of the list rather than shown as "not applicable", and a
-- feature whose companion addon is switched off says so on its card
-- instead of offering a checkbox that writes a setting nothing reads.
------------------------------------------------------------------------
local function InitializeSetupWizard()
    local RC = _G.Readycheck
    if not RC then C_Timer.After(0.1, InitializeSetupWizard) return end
    if not RC.UI then C_Timer.After(0.3, InitializeSetupWizard) return end
    if not RC.db then C_Timer.After(0.3, InitializeSetupWizard) return end

    RC.SetupWizard = RC.SetupWizard or {}
    local Wizard = RC.SetupWizard

    local MIN_W, MIN_H = 580, 540
    local MAX_W, MAX_H = 900, 800
    local HEADER_H  = 30
    local NAV_H     = 52
    local STEPBAR_H = 30
    local PAD       = 10

    -- Every furniture fill in the wizard is this flat white pixel, vertex
    -- coloured. The statusbar texture (RC:GetTexturePath) is a gradient
    -- reserved for real bars, and none of these surfaces are bars - which
    -- is also why nothing here is added to RC.trackedTextures any more:
    -- that list re-applies the statusbar texture on a texture change.
    local FLAT = (RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8"

    local function MakeFontString(parent, size, outline)
        local fs = parent:CreateFontString(nil, "OVERLAY")
        RC:ApplyCustomFont(fs, size or 12, outline or "OUTLINE")
        if RC.trackedFonts then table.insert(RC.trackedFonts, fs) end
        fs._wrFontSize    = size    or 12
        fs._wrFontOutline = outline or "OUTLINE"
        return fs
    end

    local function C(cat, key)
        if RC.GetColor then return RC:GetColor(cat, key) end
        return {r=0.9, g=0.9, b=0.9, a=1}
    end

    local function MakeButton(parent, text, h)
        return RC.UI:CreateStyledButton(parent, text, 110, h or 28)
    end

    -- 1px rule. Gold (alpha 0.6) only directly under a title; every other
    -- section break is the plain black border colour.
    local function MakeDivider(parent, anchorFrame, yOff, underTitle)
        local div = parent:CreateTexture(nil, "ARTWORK")
        div:SetPoint("TOPLEFT",  anchorFrame, "BOTTOMLEFT",  0, yOff or -6)
        div:SetPoint("TOPRIGHT", parent,      "TOPRIGHT",    0, 0)
        div:SetHeight(1)
        div:SetTexture(FLAT)
        if underTitle then
            local accent = C("ui", "accentGold")
            div:SetVertexColor(accent.r, accent.g, accent.b, 0.6)
        else
            local bord = C("ui", "borderNormal")
            div:SetVertexColor(bord.r, bord.g, bord.b, bord.a or 1)
        end
        return div
    end

    -- Card shell: flat cardBackground fill, 1px border at 0.55 and the
    -- 3px gold bar down the left edge that marks a titled section.
    local function DressCard(card)
        card.bg = card:CreateTexture(nil, "BACKGROUND")
        card.bg:SetAllPoints()
        card.bg:SetTexture(FLAT)
        local cbg = C("ui", "cardBackground")
        card.bg:SetVertexColor(cbg.r, cbg.g, cbg.b, cbg.a or 1)
        if RC.UI and RC.UI.CreateSimpleBorder then
            card.border = RC.UI:CreateSimpleBorder(card)
            if RC.UI.UpdateBorderColor then
                RC.UI:UpdateBorderColor(card.border, C("ui", "borderNormal"), 0.55)
            end
        end
        local accent = C("ui", "accentGold")
        card.accentBar = card:CreateTexture(nil, "ARTWORK")
        card.accentBar:SetWidth(3)
        card.accentBar:SetPoint("TOPLEFT",    card, "TOPLEFT",    0, 0)
        card.accentBar:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 0, 0)
        card.accentBar:SetTexture(FLAT)
        card.accentBar:SetVertexColor(accent.r, accent.g, accent.b, 0.8)
        return card
    end

    local function AddonOn(name)
        if not name then return true end
        local IsLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
        return (IsLoaded and IsLoaded(name)) and true or false
    end

    -- addon: the companion the feature lives in. Off = the checkbox is
    -- taken away and the card says what to enable; the hidden checkbox
    -- is still there so the step's OnClick wiring needs no guard.
    local function MakeFeatureCard(parent, iconTex, titleStr, descStr, isChecked, addon)
        local ICON_S  = 28
        local CB_AREA = 72

        local card = CreateFrame("Frame", nil, parent)
        card:SetHeight(80)
        DressCard(card)

        local gold = C("ui",   "headerText")
        local norm = C("text", "normal") or {r=0.85,g=0.85,b=0.85,a=1}

        local icn = card:CreateTexture(nil, "ARTWORK")
        icn:SetSize(ICON_S, ICON_S)
        icn:SetPoint("LEFT", card, "LEFT", PAD, 0)
        icn:SetTexture(iconTex)

        local cbHolder = CreateFrame("Frame", nil, card)
        cbHolder:SetSize(CB_AREA, 22)
        cbHolder:SetPoint("RIGHT", card, "RIGHT", -PAD, 0)

        local lbl = MakeFontString(card, 12, "OUTLINE")
        lbl:SetPoint("TOPLEFT", icn,      "TOPRIGHT",  8,  -5)
        lbl:SetPoint("RIGHT",   cbHolder, "LEFT",     -6,   0)
        lbl:SetText(titleStr)
        lbl:SetTextColor(gold.r, gold.g, gold.b, 1)

        local desc = MakeFontString(card, 10, "")
        desc:SetPoint("TOPLEFT", lbl,      "BOTTOMLEFT", 0,  -3)
        desc:SetPoint("RIGHT",   cbHolder, "LEFT",      -6,   0)
        desc:SetJustifyH("LEFT")
        desc:SetText(descStr)
        desc:SetTextColor(norm.r, norm.g, norm.b, 1)

        local cb = RC.UI:CreateCheckbox(cbHolder, "", isChecked and true or false)
        cb:ClearAllPoints()
        cb:SetPoint("LEFT", cbHolder, "LEFT", 0, 0)

        local cblbl = MakeFontString(cbHolder, 11, "OUTLINE")
        cblbl:SetPoint("LEFT", cb, "RIGHT", 5, 0)
        cblbl:SetText(RCL["Enable"])
        cblbl:SetTextColor(norm.r, norm.g, norm.b, 1)

        card.checkbox    = cbHolder
        card.checkbox.cb = cb

        if not AddonOn(addon) then
            cbHolder:Hide()
            local warn = C("text", "red") or {r=1,g=0.4,b=0.4,a=1}
            local need = MakeFontString(card, 10, "")
            need:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -3)
            need:SetPoint("RIGHT",   card, "RIGHT",    -PAD, 0)
            need:SetJustifyH("LEFT")
            need:SetText(string.format(RCL["Needs the %s addon - enable it in your AddOns list and /reload."], addon))
            need:SetTextColor(warn.r, warn.g, warn.b, 1)
            desc:SetPoint("RIGHT", card, "RIGHT", -PAD, 0)
            card:SetHeight(92)
        end

        return card
    end

    local function MakeInfoCard(parent, iconTex, titleStr, descStr)
        local ICON_S = 28

        local card = CreateFrame("Frame", nil, parent)
        card:SetHeight(80)
        DressCard(card)

        local gold = C("ui",   "headerText")
        local norm = C("text", "normal") or {r=0.85,g=0.85,b=0.85,a=1}

        local icn = card:CreateTexture(nil, "ARTWORK")
        icn:SetSize(ICON_S, ICON_S)
        icn:SetPoint("LEFT", card, "LEFT", PAD, 0)
        icn:SetTexture(iconTex)

        local lbl = MakeFontString(card, 12, "OUTLINE")
        lbl:SetPoint("TOPLEFT", icn,  "TOPRIGHT",   8,  -5)
        lbl:SetPoint("RIGHT",   card, "RIGHT",    -PAD,  0)
        lbl:SetJustifyH("LEFT")
        lbl:SetText(titleStr)
        lbl:SetTextColor(gold.r, gold.g, gold.b, 1)

        local desc = MakeFontString(card, 10, "")
        desc:SetPoint("TOPLEFT", lbl,  "BOTTOMLEFT",  0,  -3)
        desc:SetPoint("RIGHT",   card, "RIGHT",     -PAD,  0)
        desc:SetJustifyH("LEFT")
        desc:SetText(descStr)
        desc:SetTextColor(norm.r, norm.g, norm.b, 1)

        return card
    end

    local function PlaceCard(card, parent, anchorFrame, gap)
        card:SetPoint("TOPLEFT",  anchorFrame, "BOTTOMLEFT",  0, -(gap or 8))
        card:SetPoint("TOPRIGHT", parent,      "TOPRIGHT",    0,  0)
    end

    local function StepHeader(p, titleStr, descStr)
        local gold   = C("ui",   "headerText")
        local norm   = C("text", "normal") or {r=0.85,g=0.85,b=0.85,a=1}

        local title = MakeFontString(p, 15, "OUTLINE")
        title:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, -4)
        title:SetText(titleStr)
        title:SetTextColor(gold.r, gold.g, gold.b, 1)

        local desc = MakeFontString(p, 10, "")
        desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0,   -4)
        desc:SetPoint("RIGHT",   p,     "RIGHT",     -PAD,  0)
        desc:SetJustifyH("LEFT")
        desc:SetText(descStr)
        desc:SetTextColor(norm.r, norm.g, norm.b, 1)

        return MakeDivider(p, desc, -6, true)
    end

    local function StepHint(p, anchorFrame, text)
        local gray = C("text", "gray") or {r=0.6,g=0.6,b=0.6,a=1}
        local h = MakeFontString(p, 10, "")
        h:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", 0,   -8)
        h:SetPoint("RIGHT",   p,           "RIGHT",     -PAD,  0)
        h:SetJustifyH("LEFT")
        h:SetText(text)
        h:SetTextColor(gray.r, gray.g, gray.b, 1)
        return h
    end

    local steps = {}

    steps[1] = {
        id    = "welcome",
        title = RCL["Welcome"],
        icon  = "Interface\\Icons\\Ability_Warrior_BattleShout",
        build = function(p)
            local gold   = C("ui",   "headerText")
            local norm   = C("text", "normal") or {r=0.85,g=0.85,b=0.85,a=1}
            local gray   = C("text", "gray")   or {r=0.60,g=0.60,b=0.60,a=1}

            local heroIcon = p:CreateTexture(nil, "ARTWORK")
            heroIcon:SetSize(48, 48)
            heroIcon:SetPoint("TOP", p, "TOP", 0, -8)
            heroIcon:SetTexture("Interface\\AddOns\\Readycheck\\Media\\Checkmark")
            -- the mark flips over and back under the mouse, as it does
            -- on every window and the minimap button
            local heroFlip = RC.UI.CreateMarkFlip and RC.UI:CreateMarkFlip(heroIcon)
            if heroFlip then
                local hover = CreateFrame("Frame", nil, p)
                hover:SetAllPoints(heroIcon)
                if hover.SetMouseMotionEnabled and hover.SetMouseClickEnabled then
                    hover:SetMouseMotionEnabled(true)
                    hover:SetMouseClickEnabled(false)
                else
                    hover:EnableMouse(true)
                end
                hover:SetScript("OnEnter", function() heroFlip:Play() end)
            end

            local title = MakeFontString(p, 20, "OUTLINE")
            title:SetPoint("TOP", heroIcon, "BOTTOM", 0, -6)
            title:SetPoint("LEFT",  p, "LEFT",  0, 0)
            title:SetPoint("RIGHT", p, "RIGHT", 0, 0)
            title:SetJustifyH("CENTER")
            title:SetText(RCL["Readycheck"])
            title:SetTextColor(gold.r, gold.g, gold.b, 1)

            local sub = MakeFontString(p, 11, "")
            sub:SetPoint("TOP",   title, "BOTTOM", 0, -3)
            sub:SetPoint("LEFT",  p,     "LEFT",   0, 0)
            sub:SetPoint("RIGHT", p,     "RIGHT",  0, 0)
            sub:SetJustifyH("CENTER")
            sub:SetText(RCL["Setup Wizard"])
            sub:SetTextColor(gray.r, gray.g, gray.b, 1)

            local div = MakeDivider(p, sub, -10, true)

            local features = {
                {icon = "Interface\\Icons\\INV_Potion_54",           title = RCL["Consumables & Potions"],   desc = RCL["Track flasks, food, elixirs, weapon enchants and combat potions."]},
                {icon = "Interface\\Icons\\INV_Trinket_Naxxramas04", title = RCL["Trinket Auto-Swap"],       desc = RCL["Automatically rotate on-use trinkets during combat."]},
                {icon = "Interface\\Icons\\INV_Chest_Plate16",       title = RCL["Gear Manager"],            desc = RCL["Create gear sets and equip them with a single click."]},
                {icon = "Interface\\Icons\\Spell_Holy_WordFortitude", title = RCL["Buff & Debuff Trackers"], desc = RCL["Time left on your raid buffs and on the debuffs on the boss, with warnings before they drop."]},
            }
            if RC.isWarrior then
                table.insert(features, {icon = "Interface\\Icons\\Spell_Shadow_DeathPact",      title = RCL["Boss Reminders"],       desc = RCL["Animated alerts tuned per boss across MC, BWL, AQ40 and Naxx."]})
                table.insert(features, {icon = "Interface\\Icons\\Ability_Warrior_BattleShout", title = RCL["Battle Shout Reminder"], desc = RCL["Alerts when Battle Shout drops off any group member."]})
            end

            local prevBottom = div
            for i, feat in ipairs(features) do
                local card = CreateFrame("Frame", nil, p)
                card:SetPoint("TOPLEFT",  prevBottom, "BOTTOMLEFT",  0, i == 1 and -8 or -4)
                card:SetPoint("TOPRIGHT", p,          "TOPRIGHT",    0,  0)
                card:SetHeight(40)
                DressCard(card)

                local ic = card:CreateTexture(nil, "ARTWORK")
                ic:SetSize(24, 24)
                ic:SetPoint("LEFT", card, "LEFT", 10, 0)
                ic:SetTexture(feat.icon)

                local ftitle = MakeFontString(card, 11, "OUTLINE")
                ftitle:SetPoint("TOPLEFT", ic, "TOPRIGHT", 8, 2)
                ftitle:SetPoint("RIGHT",   card, "RIGHT", -PAD, 0)
                ftitle:SetText(feat.title)
                ftitle:SetTextColor(gold.r, gold.g, gold.b, 1)

                local fdesc = MakeFontString(card, 10, "")
                fdesc:SetPoint("TOPLEFT", ftitle, "BOTTOMLEFT", 0, -2)
                fdesc:SetPoint("RIGHT",   card,   "RIGHT",    -PAD, 0)
                fdesc:SetJustifyH("LEFT")
                fdesc:SetText(feat.desc)
                fdesc:SetTextColor(norm.r, norm.g, norm.b, 0.85)

                prevBottom = card
            end

            local hint = MakeFontString(p, 10, "")
            hint:SetPoint("TOPLEFT",  prevBottom, "BOTTOMLEFT",  0, -10)
            hint:SetPoint("TOPRIGHT", p,          "TOPRIGHT",     0,   0)
            hint:SetJustifyH("CENTER")
            hint:SetText(RCL["Each step is a few switches. Everything can be changed later with |cffffd700/rc|r or the minimap button, and Skip setup keeps the defaults. Finish ends with a short tour of the settings window."])
            hint:SetTextColor(gray.r, gray.g, gray.b, 1)
        end
    }

    steps[2] = {
        id    = "consumables",
        title = RCL["Consumables"],
        icon  = "Interface\\Icons\\INV_Potion_54",
        build = function(p)
            local div = StepHeader(p, "Consumables Bars",
                "These bars show icons on your screen for each tracked buff. They glow when a buff is missing or about to expire.")

            local c1 = MakeFeatureCard(p,
                "Interface\\Icons\\INV_Potion_41", "Consumables Bar",
                "Tracks your flask, food, elixir and other consumable buffs. Shows a glowing icon for each buff that is missing or about to expire.",
                RC.db.consumablesHelper and RC.db.consumablesHelper.enabled, "Readycheck_Consumables")
            PlaceCard(c1, p, div)
            c1.checkbox.cb:SetScript("OnClick", function(self)
                local v = self:GetChecked()
                if not RC.db.consumablesHelper then RC.db.consumablesHelper = {} end
                RC.db.consumablesHelper.enabled = v
                RC:SaveConfigurationToProfile()
                RC:DebugPrint("SetupWizard: consumablesHelper="..tostring(v), "wizard")
            end)

            local c2 = MakeFeatureCard(p,
                "Interface\\Icons\\INV_Potion_54", "Potions Bar",
                "Tracks combat potions like Mighty Rage Potion and Greater Fire Protection Potion. Shows when they are ready to use.",
                RC.db.potionsBar and RC.db.potionsBar.enabled, "Readycheck_Consumables")
            PlaceCard(c2, p, c1)
            c2.checkbox.cb:SetScript("OnClick", function(self)
                local v = self:GetChecked()
                if not RC.db.potionsBar then RC.db.potionsBar = {} end
                RC.db.potionsBar.enabled = v
                RC:SaveConfigurationToProfile()
                RC:DebugPrint("SetupWizard: potionsBar="..tostring(v), "wizard")
            end)

            local c3 = MakeFeatureCard(p,
                "Interface\\Icons\\INV_Stone_SharpeningStone_01", "Weapon Enchant Bar",
                "Tracks temporary weapon enchants like Sharpening Stones. Alerts you when they are about to expire so you can reapply before a pull.",
                RC.db.weaponsBar and RC.db.weaponsBar.enabled, "Readycheck_Consumables")
            PlaceCard(c3, p, c2)
            c3.checkbox.cb:SetScript("OnClick", function(self)
                local v = self:GetChecked()
                if not RC.db.weaponsBar then RC.db.weaponsBar = {} end
                RC.db.weaponsBar.enabled = v
                RC:SaveConfigurationToProfile()
                RC:DebugPrint("SetupWizard: weaponsBar="..tostring(v), "wizard")
            end)

            StepHint(p, c3, "Type |cffffd700/rc|r and go to Sidebar > Consumables for positions, thresholds, and which buffs to track.")
        end
    }

    steps[3] = {
        id    = "trinkets",
        title = RCL["Trinkets"],
        icon  = "Interface\\Icons\\INV_Trinket_Naxxramas04",
        build = function(p)
            local div = StepHeader(p, "Trinket Auto-Swap",
                "Automatically rotates on-use trinkets during combat. Queue trinkets and the system equips the next one as soon as the previous buff expires.")

            local c1 = MakeFeatureCard(p,
                "Interface\\Icons\\INV_Trinket_Naxxramas04", "Automatic Trinket Rotation",
                "Enables the trinket swap system. Monitors cooldowns and equips the next queued trinket the moment the previous one is ready.",
                RC.db.trinketSwap and RC.db.trinketSwap.enabled, "Readycheck_Gear")
            PlaceCard(c1, p, div)
            c1.checkbox.cb:SetScript("OnClick", function(self)
                local v = self:GetChecked()
                if not RC.db.trinketSwap then RC.db.trinketSwap = {} end
                RC.db.trinketSwap.enabled = v
                RC:SaveConfigurationToProfile()
                RC:DebugPrint("SetupWizard: trinketSwap="..tostring(v), "wizard")
            end)

            local c2 = MakeFeatureCard(p,
                "Interface\\Icons\\INV_Misc_Note_01", "Trinket Swap Toggle Button",
                "Shows a small on/off button on screen so you can quickly pause or resume the swap system mid-session without opening any menus.",
                RC.db.trinketSwap and RC.db.trinketSwap.showToggleButton, "Readycheck_Gear")
            PlaceCard(c2, p, c1)
            c2.checkbox.cb:SetScript("OnClick", function(self)
                local v = self:GetChecked()
                if not RC.db.trinketSwap then RC.db.trinketSwap = {} end
                RC.db.trinketSwap.showToggleButton = v
                if v and RC.ShowTrinketToggleButton then RC:ShowTrinketToggleButton()
                elseif not v and RC.HideTrinketToggleButton then RC:HideTrinketToggleButton() end
                RC:SaveConfigurationToProfile()
                RC:DebugPrint("SetupWizard: showToggleButton="..tostring(v), "wizard")
            end)

            StepHint(p, c2, "Type |cffffd700/rc|r and go to Sidebar > Trinket Manager to add trinkets to the queue and set priorities.")
        end
    }

    steps[4] = {
        id    = "gear",
        title = RCL["Gear Manager"],
        icon  = "Interface\\Icons\\INV_Chest_Plate16",
        build = function(p)
            local div = StepHeader(p, "Gear Manager",
                "Create named gear sets and bind them to on-screen buttons. Click a button to equip that full set instantly.")

            local c1 = MakeFeatureCard(p,
                "Interface\\Icons\\INV_Chest_Plate16", "Gear Manager",
                "Shows on-screen gear set buttons. Click one to equip that set immediately. Right-click to configure which set it uses. Supports ItemRack.",
                RC.db.gearManager and RC.db.gearManager.enabled, "Readycheck_Gear")
            PlaceCard(c1, p, div)
            c1.checkbox.cb:SetScript("OnClick", function(self)
                local v = self:GetChecked()
                if not RC.db.gearManager then RC.db.gearManager = {} end
                RC.db.gearManager.enabled = v
                if RC.GearManager then
                    if v then
                        if RC.GearManager.Enable then RC.GearManager:Enable() end
                    else
                        if RC.GearManager.Disable then RC.GearManager:Disable() end
                    end
                end
                RC:SaveConfigurationToProfile()
                RC:DebugPrint("SetupWizard: gearManager="..tostring(v), "wizard")
            end)

            StepHint(p, c1, "Type |cffffd700/rc|r and go to Sidebar > Gear Manager for gear sets, hotswap, and full configuration.")
        end
    }

    steps[5] = {
        id    = "reminders",
        title = RCL["Reminders"],
        icon  = "Interface\\Icons\\Spell_Shadow_DeathPact",
        build = function(p)
            if RC.isWarrior then
                local div = StepHeader(p, "Ability Reminders & Alerts",
                    "Shows animated icons on screen when key abilities are ready. Works with raid boss configs to fire reminders at the right moment.")

                local c1 = MakeFeatureCard(p,
                    "Interface\\Icons\\Spell_Shadow_DeathPact", "Ability Reminders",
                    "Master switch for all reminder animations. Watches for Death Wish, Recklessness, trinkets, and other cooldowns becoming ready.",
                    RC.db.enabled, "Readycheck_Reminders")
                PlaceCard(c1, p, div)
                c1.checkbox.cb:SetScript("OnClick", function(self) RC.db.enabled = self:GetChecked(); RC:SaveConfigurationToProfile() end)

                local c2 = MakeFeatureCard(p,
                    "Interface\\Icons\\Ability_Ambush", "Sound Alerts",
                    "Plays a sound when a reminder fires. Pairs with visual animations so you never miss a cooldown in a hectic fight.",
                    RC.db.soundEnabled, "Readycheck_Reminders")
                PlaceCard(c2, p, c1)
                c2.checkbox.cb:SetScript("OnClick", function(self) RC.db.soundEnabled = self:GetChecked(); RC:SaveConfigurationToProfile() end)

                local c3 = MakeFeatureCard(p,
                    "Interface\\Icons\\INV_Misc_Note_01", "Text-to-Speech",
                    "Master switch for the spoken voice. Speaks the ability name when a reminder fires, and gates every other spoken alert - consumables, bars, boss notes and equipment warnings.",
                    RC.db.ttsEnabled)
                PlaceCard(c3, p, c2)
                c3.checkbox.cb:SetScript("OnClick", function(self) RC.db.ttsEnabled = self:GetChecked(); RC:SaveConfigurationToProfile() end)
            else
                local div = StepHeader(p, "General Reminders",
                    "Master switch for the addon. Controls whether reminders and alerts are active.")

                local c1 = MakeFeatureCard(p,
                    "Interface\\Icons\\Spell_Shadow_DeathPact", "Addon Enabled",
                    "Master on/off switch. Disabling stops all reminders, bars, and alerts from firing.",
                    RC.db.enabled)
                PlaceCard(c1, p, div)
                c1.checkbox.cb:SetScript("OnClick", function(self) RC.db.enabled = self:GetChecked(); RC:SaveConfigurationToProfile() end)
            end
        end
    }

    -- Warriors only: `when` keeps it out of the list for everyone else
    -- (see the compaction below) instead of showing a step that says
    -- "not applicable, click Next".
    steps[6] = {
        id    = "battleshout",
        title = RCL["Battle Shout"],
        icon  = "Interface\\Icons\\Ability_Warrior_BattleShout",
        when  = function() return RC.isWarrior and true or false end,
        build = function(p)
            local div = StepHeader(p, "Battle Shout Reminder",
                "Battle Shout gives your whole group attack power. This reminder fires when the buff falls off any nearby group member.")

            local c1 = MakeFeatureCard(p,
                "Interface\\Icons\\Ability_Warrior_BattleShout", "Battle Shout Reminder",
                "Alerts you when Battle Shout expires on group members. Fires before full expiry so you have time to recast before the buff is lost.",
                RC.db.battleShoutReminder and RC.db.battleShoutReminder.enabled, "Readycheck_Reminders")
            PlaceCard(c1, p, div)
            c1.checkbox.cb:SetScript("OnClick", function(self)
                local v = self:GetChecked()
                if not RC.db.battleShoutReminder then RC.db.battleShoutReminder = {} end
                RC.db.battleShoutReminder.enabled = v
                RC:SaveConfigurationToProfile()
                RC:DebugPrint("SetupWizard: battleShout="..tostring(v), "wizard")
            end)

            StepHint(p, c1, "Type |cffffd700/rc|r and go to Sidebar > Battle Shout Reminder to configure who to check (party, full raid, etc.).")
        end
    }

    steps[7] = {
        id    = "trackers",
        title = RCL["Buff & Debuff Trackers"],
        icon  = "Interface\\Icons\\Spell_Holy_WordFortitude",
        build = function(p)
            local div = StepHeader(p, RCL["Buff & Debuff Trackers"],
                RCL["Two small lists that show time left: one for the raid buffs on you, one for the raid's debuffs on the boss. Both can speak a warning before something drops, and can whisper whoever cast it once it has run out (off unless you turn it on)."])

            local c1 = MakeFeatureCard(p,
                "Interface\\Icons\\Spell_Holy_WordFortitude", RCL["Raid Buff Tracker"],
                RCL["Fortitude, Intellect, Mark of the Wild, the Blessings and the rest, with how long each has left. Warns you before they run out."],
                RC.db.raidBuffTracker and RC.db.raidBuffTracker.enabled, "Readycheck_Reminders")
            PlaceCard(c1, p, div)
            c1.checkbox.cb:SetScript("OnClick", function(self)
                local v = self:GetChecked()
                if not RC.db.raidBuffTracker then RC.db.raidBuffTracker = {} end
                RC.db.raidBuffTracker.enabled = v
                if RC.RefreshRaidBuffTracker then RC:RefreshRaidBuffTracker() end
                RC:SaveConfigurationToProfile()
                RC:DebugPrint("SetupWizard: raidBuffTracker="..tostring(v), "wizard")
            end)

            local c2 = MakeFeatureCard(p,
                "Interface\\Icons\\Spell_Nature_FaerieFire", RCL["Boss Debuff Tracker"],
                RCL["Sunder, the curses, Faerie Fire, Scorch stacks and the rest on your target, with time left and stacks. Calls out anything about to drop or already missing."],
                RC.db.bossDebuffTracker and RC.db.bossDebuffTracker.enabled, "Readycheck_Reminders")
            PlaceCard(c2, p, c1)
            c2.checkbox.cb:SetScript("OnClick", function(self)
                local v = self:GetChecked()
                if not RC.db.bossDebuffTracker then RC.db.bossDebuffTracker = {} end
                RC.db.bossDebuffTracker.enabled = v
                if RC.RefreshBossDebuffTracker then RC:RefreshBossDebuffTracker() end
                RC:SaveConfigurationToProfile()
                RC:DebugPrint("SetupWizard: bossDebuffTracker="..tostring(v), "wizard")
            end)

            StepHint(p, c2, RCL["Which buffs and debuffs to track, the warning times and the whisper option are under |cffffd700/rc|r > Extras."])
        end
    }

    steps[8] = {
        id    = "raids",
        title = RCL["Raids"],
        icon  = "Interface\\Icons\\INV_Misc_Book_09",
        build = function(p)
            local div = StepHeader(p, RCL["Raid Profiles and Kill Timers"],
                RCL["Each raid has a page per boss for gear swaps, trinkets, reminders and notes, and can have more than one profile - Farm, Progression, per spec. Switching profiles re-applies everything in one click."])

            local c1 = MakeInfoCard(p,
                "Interface\\Icons\\INV_Misc_Note_01", RCL["Profile Picker on Zone-In"],
                RCL["When you enter a raid with more than one profile, a picker asks which to load. With one profile it loads silently. Presets for every raid can be imported on the last step."])
            PlaceCard(c1, p, div)

            local c2 = MakeFeatureCard(p,
                "Interface\\Icons\\Spell_Holy_BorrowedTime", RCL["TTK Display"],
                RCL["Shows a predicted time-to-kill as you fight, learned from your own logged kills. Each profile keeps its own kill history, so Farm numbers are not muddied by Progression wipes."],
                RC.db.ttkDisplay and RC.db.ttkDisplay.enabled, "Readycheck_Reminders")
            PlaceCard(c2, p, c1)
            c2.checkbox.cb:SetScript("OnClick", function(self)
                local v = self:GetChecked()
                if not RC.db.ttkDisplay then RC.db.ttkDisplay = {} end
                RC.db.ttkDisplay.enabled = v
                if RC.UpdateTTKDisplayActive then RC:UpdateTTKDisplayActive() end
                RC:SaveConfigurationToProfile()
                RC:DebugPrint("SetupWizard: ttkDisplay="..tostring(v), "wizard")
            end)

            StepHint(p, c2, RCL["Open |cffffd700/rc|r > Raids to set up bosses or add profiles. Right-click any kill in a boss History tab to move it to another profile."])
        end
    }

    steps[9] = {
        id    = "extras",
        title = RCL["Custom Reminders + Extras"],
        icon  = "Interface\\Icons\\INV_Inscription_Scroll",
        build = function(p)
            local div = StepHeader(p, "Author Your Own Reminders + Other Tools",
                "Custom Reminders lets you build your own on-screen reminders with custom triggers (cast, buff, debuff, HP threshold, aura missing, etc.) and conditions. Chronoboon Reminder tracks your Chronoboon Displacer, and Boss Notes shows per-boss notes you write yourself.")

            local c1 = MakeFeatureCard(p,
                "Interface\\Icons\\inv_misc_enggizmos_24", "Chronoboon Reminder",
                "Tells you when your Chronoboon buff is missing or about to expire. Mode can be Always, Raid-only, or Boss-only so it isn't noisy outside raids.",
                RC.db.boonReminder and RC.db.boonReminder.enabled, "Readycheck_Reminders")
            PlaceCard(c1, p, div)
            c1.checkbox.cb:SetScript("OnClick", function(self)
                local v = self:GetChecked()
                if not RC.db.boonReminder then RC.db.boonReminder = {} end
                RC.db.boonReminder.enabled = v
                RC:SaveConfigurationToProfile()
                RC:DebugPrint("SetupWizard: boonReminder="..tostring(v), "wizard")
            end)

            local c2 = MakeFeatureCard(p,
                "Interface\\Icons\\INV_Misc_Note_02", "Boss Notes Overlay",
                "Shows short notes you've written for each boss when you target them. Useful for 'remember to do X here' reminders. Can be scoped per-profile so Farm notes differ from Prog notes.",
                RC.db.bossNotes and RC.db.bossNotes.enabled, "Readycheck_Features")
            PlaceCard(c2, p, c1)
            c2.checkbox.cb:SetScript("OnClick", function(self)
                local v = self:GetChecked()
                if not RC.db.bossNotes then RC.db.bossNotes = {} end
                RC.db.bossNotes.enabled = v
                RC:SaveConfigurationToProfile()
                RC:DebugPrint("SetupWizard: bossNotes="..tostring(v), "wizard")
            end)

            StepHint(p, c2, "Custom Reminders is always available - open |cffffd700/rc|r > Custom Reminders to author your own. UI Mover (in the Interface page) lets you relocate any frame with optional snap-to-grid.")
        end
    }

    steps[10] = {
        id    = "done",
        title = RCL["All Done!"],
        icon  = "Interface\\Icons\\Achievement_General",
        build = function(p)
            local gold   = C("ui",   "headerText")
            local norm   = C("text", "normal") or {r=0.85,g=0.85,b=0.85,a=1}
            local gray   = C("text", "gray")   or {r=0.60,g=0.60,b=0.60,a=1}
            local accent = C("ui",   "accentGold")

            local title = MakeFontString(p, 18, "OUTLINE")
            title:SetPoint("TOP", p, "TOP", 0, -8)
            title:SetText(RCL["You're all set!"])
            title:SetTextColor(gold.r, gold.g, gold.b, 1)

            local topDiv = p:CreateTexture(nil, "ARTWORK")
            topDiv:SetPoint("LEFT",  p,     "LEFT",   0, 0)
            topDiv:SetPoint("RIGHT", p,     "RIGHT",  0, 0)
            topDiv:SetPoint("TOP",   title, "BOTTOM", 0, -8)
            topDiv:SetHeight(1)
            topDiv:SetTexture(FLAT)
            topDiv:SetVertexColor(accent.r, accent.g, accent.b, 0.6)

            local sub = MakeFontString(p, 10, "")
            sub:SetPoint("LEFT",  p,      "LEFT",   0,  0)
            sub:SetPoint("RIGHT", p,      "RIGHT",  0,  0)
            sub:SetPoint("TOP",   topDiv, "BOTTOM", 0, -6)
            sub:SetJustifyH("CENTER")
            sub:SetText(RCL["Settings are saved per-character. Summary of what you enabled:"])
            sub:SetTextColor(norm.r, norm.g, norm.b, 1)

            local summaryData = {
                {label = RCL["Consumables Bar"], get = function() return RC.db.consumablesHelper and RC.db.consumablesHelper.enabled end},
                {label = RCL["Potions Bar"],     get = function() return RC.db.potionsBar and RC.db.potionsBar.enabled end},
                {label = RCL["Weapon Bar"],      get = function() return RC.db.weaponsBar and RC.db.weaponsBar.enabled end},
                {label = RCL["Trinket Swap"],    get = function() return RC.db.trinketSwap and RC.db.trinketSwap.enabled end},
                {label = RCL["Gear Manager"],    get = function() return RC.db.gearManager and RC.db.gearManager.enabled end},
                {label = RCL["TTK Display"],     get = function() return RC.db.ttkDisplay and RC.db.ttkDisplay.enabled end},
                {label = RCL["Chronoboon Reminder"], get = function() return RC.db.boonReminder and RC.db.boonReminder.enabled end},
                {label = RCL["Boss Notes"],      get = function() return RC.db.bossNotes and RC.db.bossNotes.enabled end},
            }
            if RC.isWarrior then
                table.insert(summaryData, {label = RCL["Ability Reminders"], get = function() return RC.db.enabled end})
                table.insert(summaryData, {label = RCL["Battle Shout"],      get = function() return RC.db.battleShoutReminder and RC.db.battleShoutReminder.enabled end})
            end

            local ROW_H = 16    -- 10 rows + presets + hints must fit the page at MIN_H
            local sCard = CreateFrame("Frame", nil, p)
            sCard:SetHeight(#summaryData * ROW_H + 14)
            sCard:SetPoint("LEFT",   p,   "LEFT",   0,  0)
            sCard:SetPoint("RIGHT",  p,   "RIGHT",  0,  0)
            sCard:SetPoint("TOP",    sub, "BOTTOM", 0, -8)
            sCard.bg = sCard:CreateTexture(nil, "BACKGROUND")
            sCard.bg:SetAllPoints()
            sCard.bg:SetTexture(FLAT)
            local sbg = C("ui", "elementBackground")
            sCard.bg:SetVertexColor(sbg.r, sbg.g, sbg.b, 1)
            if RC.UI and RC.UI.CreateSimpleBorder then RC.UI:CreateSimpleBorder(sCard) end

            local cy = -7
            local valueTexts = {}
            for i, entry in ipairs(summaryData) do
                local lbl = MakeFontString(sCard, 10, "OUTLINE")
                lbl:SetPoint("TOPLEFT",  sCard, "TOPLEFT",  12, cy)
                lbl:SetText(entry.label)
                lbl:SetTextColor(norm.r, norm.g, norm.b, 1)
                local val = MakeFontString(sCard, 10, "OUTLINE")
                val:SetPoint("TOPRIGHT", sCard, "TOPRIGHT", -12, cy)
                valueTexts[i] = val
                cy = cy - ROW_H
            end

            -- Called by ShowStep every time this pooled step container is
            -- shown, so the summary reflects toggles made on earlier steps
            -- after the container was first built.
            p.RefreshOnShow = function()
                for i, entry in ipairs(summaryData) do
                    valueTexts[i]:SetText(entry.get() and RCL["|cff66ff66Enabled|r"] or RCL["|cff888888Disabled|r"])
                end
            end
            p.RefreshOnShow()

            local lastAnchor = sCard

            if RC.builtInProfiles and RC.ImportRaidProfile then
                local raidList = {}
                for raidName, profiles in pairs(RC.builtInProfiles) do
                    if profiles and #profiles > 0 then
                        table.insert(raidList, {name = raidName, profiles = profiles})
                    end
                end
                table.sort(raidList, function(a, b) return a.name < b.name end)

                if #raidList > 0 then
                    local rDiv = MakeDivider(p, sCard, -10)

                    local rTitle = MakeFontString(p, 12, "OUTLINE")
                    rTitle:SetPoint("TOPLEFT",  rDiv, "BOTTOMLEFT",  0, -6)
                    rTitle:SetPoint("TOPRIGHT", p,    "TOPRIGHT",    0,  0)
                    rTitle:SetJustifyH("CENTER")
                    rTitle:SetText(RCL["Import a Raid Configuration Preset"])
                    rTitle:SetTextColor(gold.r, gold.g, gold.b, 1)

                    local prevAnchor = rTitle
                    for _, raidEntry in ipairs(raidList) do
                        for _, profile in ipairs(raidEntry.profiles) do
                            local importBtn = MakeButton(p, raidEntry.name .. "    -    " .. profile.name, 24)
                            importBtn:SetPoint("TOPLEFT",  prevAnchor, "BOTTOMLEFT",  0, -6)
                            importBtn:SetPoint("TOPRIGHT", p,          "TOPRIGHT",    0,  0)
                            prevAnchor = importBtn
                            lastAnchor = importBtn

                            local pData, pName, rName = profile.data, profile.name, raidEntry.name
                            importBtn:SetScript("OnClick", function()
                                if not RC.ImportRaidProfile then return end
                                -- The wizard always sets up THIS character, so
                                -- close any remote edit session first rather
                                -- than importing into someone else's config.
                                if RC.remoteEditMode and RC.ExitRemoteEditMode then
                                    RC:ExitRemoteEditMode()
                                end
                                local ok = RC:ImportRaidProfile(pData, pName)
                                if ok then
                                    -- The button's own active look (green
                                    -- fill, gold ring) is the "done" state;
                                    -- a gold fill is never furniture.
                                    importBtn:SetActive(true)
                                    importBtn.text:SetText("|cff66ff66"..rName..RCL[" - Imported!|r"])
                                    C_Timer.After(3, function()
                                        if importBtn and importBtn.text then
                                            importBtn.text:SetText(rName.."  -  "..pName)
                                            importBtn:SetActive(false)
                                        end
                                    end)
                                end
                            end)
                        end
                    end
                end
            end

            local hint = MakeFontString(p, 10, "")
            hint:SetPoint("TOPLEFT",  lastAnchor, "BOTTOMLEFT",  0,  -10)
            hint:SetPoint("TOPRIGHT", p,          "TOPRIGHT",    0,    0)
            hint:SetJustifyH("CENTER")
            hint:SetText(RCL["Finish opens the settings window and shows you around it. Every feature has much more inside."])
            hint:SetTextColor(gray.r, gray.g, gray.b, 1)

            local discordDiv = MakeDivider(p, hint, -10)
            local discordLine = MakeFontString(p, 10, "")
            discordLine:SetPoint("TOPLEFT",  discordDiv, "BOTTOMLEFT",  0, -8)
            discordLine:SetPoint("TOPRIGHT", p,          "TOPRIGHT",    0,  0)
            discordLine:SetJustifyH("CENTER")
            discordLine:SetText(RCL["Questions or feedback? Find me on Discord: |cffffd700zac12|r"])
            discordLine:SetTextColor(gray.r, gray.g, gray.b, 1)
        end
    }

    do
        local meshStep = {
            id    = "mesh",
            title = RCL["Mesh Network (optional)"],
            icon  = "Interface\\Icons\\spell_nature_web",
            build = function(p)
                local gold = C("ui",   "headerText")
                local gray = C("text", "gray")   or {r=0.6,g=0.6,b=0.6,a=1}

                local div = StepHeader(p, RCL["Mesh Network (optional)"],
                    RCL["Only for playing on more than one account, or sharing with trusted friends: it syncs world buffs, raid configs and remote edits between them. If that is not you, click Next. Every account must use the same Channel Name and Mesh Password."])

                local MS = RC.MeshSync
                if not (MS and MS.GetConfig) then
                    local na = MakeFontString(p, 11, "")
                    na:SetPoint("TOPLEFT", div, "BOTTOMLEFT", 0, -10)
                    na:SetText(RCL["Mesh Network is unavailable in this session."])
                    na:SetTextColor(gray.r, gray.g, gray.b, 1)
                    return
                end
                local cfg = MS:GetConfig()

                local function statusText()
                    return "Status:  " .. (MS:IsEnabled() and "|cFF55FF66Active|r" or "|cFF999999Inactive|r")
                end
                local statusFs = MakeFontString(p, 10, "")
                statusFs:SetPoint("TOPLEFT", div, "BOTTOMLEFT", 0, -8)
                statusFs:SetText(statusText())

                local function field(labelText, anchorFrame, initial, maxLen)
                    local lbl = MakeFontString(p, 10, "OUTLINE")
                    lbl:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", 0, -10)
                    lbl:SetText(labelText)
                    lbl:SetTextColor(gold.r, gold.g, gold.b, 1)
                    local box = RC.UI:CreateStyledEditBox(p, {
                        width = 280, height = 26, maxLetters = maxLen or 60, initialText = initial or "",
                    })
                    box:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -4)
                    return box
                end

                local labelBox = field("Account Label  (shown to others)", statusFs, cfg.accountLabel or "", 15)
                local chanBox  = field("Channel Name  (same on all accounts, 16+ chars)", labelBox, cfg.discoveryChannel or "", 60)

                local passLbl = MakeFontString(p, 10, "OUTLINE")
                passLbl:SetPoint("TOPLEFT", chanBox, "BOTTOMLEFT", 0, -10)
                passLbl:SetText(RCL["Mesh Password  (identical on all accounts, 6+ chars)"])
                passLbl:SetTextColor(gold.r, gold.g, gold.b, 1)

                local realPassword = cfg.meshPassword or ""
                local passVisible  = false

                local function SavePassword(v)
                    if #v >= 6 then
                        realPassword     = v
                        cfg.meshPassword = v
                    end
                end

                local boxMasked = RC.UI:CreateStyledEditBox(p, {
                    width = 220, height = 26, maxLetters = 60, initialText = "",
                    onTextChanged = function(eb) if not passVisible then realPassword = eb:GetText() end end,
                    onFocusLost   = function(eb) if not passVisible then SavePassword(eb:GetText()) end end,
                })
                boxMasked:SetPoint("TOPLEFT", passLbl, "BOTTOMLEFT", 0, -4)
                boxMasked.editBox:SetText(realPassword)
                boxMasked.editBox:SetPassword(true)
                boxMasked.editBox:HookScript("OnEditFocusGained", function(eb) eb:HighlightText() end)

                local boxPlain = RC.UI:CreateStyledEditBox(p, {
                    width = 220, height = 26, maxLetters = 60, initialText = "",
                    onTextChanged = function(eb) if passVisible then realPassword = eb:GetText() end end,
                    onFocusLost   = function(eb) if passVisible then SavePassword(eb:GetText()) end end,
                })
                boxPlain:SetPoint("TOPLEFT", passLbl, "BOTTOMLEFT", 0, -4)
                boxPlain.editBox:SetText(realPassword)
                boxPlain.editBox:HookScript("OnEditFocusGained", function(eb) eb:HighlightText() end)
                boxPlain:Hide()

                local showPassBtn = RC.UI:CreateStyledButton(p, RCL["Show"], 50, 26)
                showPassBtn:SetPoint("LEFT", boxMasked, "RIGHT", 6, 0)
                local function refreshPass()
                    if passVisible then
                        boxPlain.editBox:SetText(realPassword);  boxPlain:Show();  boxMasked:Hide()
                    else
                        boxMasked.editBox:SetText(realPassword); boxMasked:Show(); boxPlain:Hide()
                    end
                    showPassBtn.text:SetText(passVisible and RCL["Hide"] or RCL["Show"])
                end
                showPassBtn:SetScript("OnClick", function()
                    realPassword = (passVisible and boxPlain or boxMasked).editBox:GetText()
                    passVisible  = not passVisible
                    refreshPass()
                end)
                refreshPass()

                local applyBtn = RC.UI:CreateStyledButton(p, RCL["Enable & Connect"], 150, 28)
                applyBtn:SetPoint("TOPLEFT", boxMasked, "BOTTOMLEFT", 0, -12)
                applyBtn:SetScript("OnClick", function()
                    local label = (labelBox.editBox:GetText():match("^%s*(.-)%s*$") or ""):sub(1, 15)
                    local chan  = chanBox.editBox:GetText():match("^%s*(.-)%s*$") or ""
                    local pass  = (passVisible and boxPlain or boxMasked).editBox:GetText()
                    if label == "" then
                        RC:Print(RCL["Mesh: Account Label is required."]); return
                    end
                    if chan ~= "" and #chan < 16 then
                        RC:Print(RCL["Mesh: Channel Name must be 16+ characters."]); return
                    end
                    if #pass < 6 then
                        RC:Print(RCL["Mesh: Mesh Password must be 6+ characters."]); return
                    end
                    cfg.accountLabel     = label
                    cfg.discoveryChannel = chan
                    cfg.meshPassword     = pass
                    realPassword = pass
                    refreshPass()
                    if not MS:IsEnabled() then MS:Enable() end
                    if chan ~= "" and MS.JoinDiscoveryChannel then MS:JoinDiscoveryChannel() end
                    if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
                    statusFs:SetText(statusText())
                    RC:Print(RCL["Mesh: Enabled. Channel and password saved."])
                end)

                local disableBtn = RC.UI:CreateStyledButton(p, RCL["Disable"], 90, 28)
                disableBtn:SetPoint("LEFT", applyBtn, "RIGHT", 8, 0)
                disableBtn:SetScript("OnClick", function()
                    if MS.Disable then MS:Disable() end
                    statusFs:SetText(statusText())
                    RC:Print(RCL["Mesh: Disabled on this character."])
                end)

                StepHint(p, applyBtn, "Manage connected accounts, the roster and security details any time in |cffffd700/rc|r > Mesh Network > Connection.")
            end
        }
        -- The ten literal slots above are compacted into the list the
        -- wizard walks: a slot left nil or whose `when` says no is dropped,
        -- so every remaining step applies to this character. Mesh is then
        -- spliced in one slot before "done", so it always lands
        -- second-to-last regardless of how many steps precede it.
        local ordered = {}
        for i = 1, 10 do
            local st = steps[i]
            if st and not (st.when and not st.when()) then ordered[#ordered + 1] = st end
        end
        steps = ordered
        table.insert(steps, #steps, meshStep)
    end

    function Wizard:Open()
        if not RC.db then return end

        if not RC.db.setupWizard then
            RC.db.setupWizard = {completed = false, lastStep = 1}
        end

        if self.frame then
            if self.frame:IsShown() then
                self.frame:Hide()
                return
            end
            self:ShowStep(self.currentStep or 1)
            self.frame:Show()
            self.frame:Raise()
            return
        end

        self.currentStep = RC.db.setupWizard.lastStep or 1

        local f = CreateFrame("Frame", "WRSetupWizardFrame", UIParent)
        f:SetSize(MIN_W, MIN_H)
        f:SetPoint("CENTER")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop",  f.StopMovingOrSizing)
        f:SetFrameStrata("DIALOG")
        f:SetFrameLevel(100)
        f:SetToplevel(true)
        f:SetScript("OnMouseDown", function(self) self:Raise() end)
        RC.UI:RegisterEscapeClose("WRSetupWizardFrame")
        self.frame = f

        -- Window shell: flat windowBackground fill, 1px black border, a
        -- 30px flat title bar with the gold hairline under it, 15px gold
        -- title at the left and the chromeless X at the right.
        f.bg = f:CreateTexture(nil, "BACKGROUND")
        f.bg:SetAllPoints()
        f.bg:SetTexture(FLAT)
        local winBg = C("ui", "windowBackground")
        f.bg:SetVertexColor(winBg.r, winBg.g, winBg.b, winBg.a or 0.95)
        if RC.UI and RC.UI.CreateSimpleBorder then RC.UI:CreateSimpleBorder(f) end

        local header = CreateFrame("Frame", nil, f)
        header:SetPoint("TOPLEFT",  f, "TOPLEFT",  1, -1)
        header:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
        header:SetHeight(HEADER_H)
        header.bg = header:CreateTexture(nil, "BACKGROUND")
        header.bg:SetAllPoints()
        header.bg:SetTexture(FLAT)
        local hdrBg = C("ui", "headerBackground")
        header.bg:SetVertexColor(hdrBg.r, hdrBg.g, hdrBg.b, hdrBg.a or 1)

        local ac = C("ui", "accentGold")
        local hAccent = header:CreateTexture(nil, "ARTWORK")
        hAccent:SetPoint("BOTTOMLEFT",  header, "BOTTOMLEFT")
        hAccent:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT")
        hAccent:SetHeight(1)
        hAccent:SetTexture(FLAT)
        hAccent:SetVertexColor(ac.r, ac.g, ac.b, 0.6)
        if RC.UI.ApplyHeaderArt then
            hAccent:Hide()
            RC.UI:ApplyHeaderArt(header, { stepX = 160 })
        end

        local titleIcon = RC.UI:AddTitleIcon(header, 16, 8)

        local titleText = MakeFontString(header, 15, "OUTLINE")
        titleText:SetPoint("LEFT", titleIcon, "RIGHT", 8, 0)
        titleText:SetText(RCL["Setup Wizard"])
        titleText:SetTextColor(C("ui","headerText").r, C("ui","headerText").g, C("ui","headerText").b, 1)
        f.titleText = titleText

        local closeBtn = RC.UI:CreateXCloseButton(header, 22, function() f:Hide() end)
        closeBtn:SetPoint("RIGHT", header, "RIGHT", -5, 0)

        local stepBar = CreateFrame("Frame", nil, f)
        stepBar:SetPoint("TOPLEFT",  header, "BOTTOMLEFT",  0, -4)
        stepBar:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -4)
        stepBar:SetHeight(STEPBAR_H)
        f.stepBar = stepBar
        self:BuildStepDots(stepBar, MIN_W)

        -- Section breaks are black hairlines; gold is only ever under a
        -- title (the header rule above).
        local bord = C("ui", "borderNormal")
        local dotDiv = f:CreateTexture(nil, "ARTWORK")
        dotDiv:SetPoint("TOPLEFT",  stepBar, "BOTTOMLEFT",  10, -2)
        dotDiv:SetPoint("TOPRIGHT", stepBar, "BOTTOMRIGHT", -10, -2)
        dotDiv:SetHeight(1)
        dotDiv:SetTexture(FLAT)
        dotDiv:SetVertexColor(bord.r, bord.g, bord.b, bord.a or 1)

        local content = CreateFrame("Frame", nil, f)
        content:SetPoint("TOPLEFT",  dotDiv, "BOTTOMLEFT",  4, -4)
        content:SetPoint("RIGHT",    f,      "RIGHT",      -4,  0)
        content:SetPoint("BOTTOM",   f,      "BOTTOM",      0,  NAV_H + 4)
        f.content = content

        local nav = CreateFrame("Frame", nil, f)
        nav:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",  0, 0)
        nav:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
        nav:SetHeight(NAV_H)
        f.nav = nav
        nav.bg = nav:CreateTexture(nil, "BACKGROUND")
        nav.bg:SetAllPoints()
        nav.bg:SetTexture(FLAT)
        nav.bg:SetVertexColor(hdrBg.r, hdrBg.g, hdrBg.b, 0.8)

        local navDiv = nav:CreateTexture(nil, "ARTWORK")
        navDiv:SetPoint("TOPLEFT",  nav, "TOPLEFT")
        navDiv:SetPoint("TOPRIGHT", nav, "TOPRIGHT")
        navDiv:SetHeight(1)
        navDiv:SetTexture(FLAT)
        navDiv:SetVertexColor(bord.r, bord.g, bord.b, bord.a or 1)

        local prevBtn = MakeButton(nav, "< Previous", 28)
        prevBtn:SetWidth(110)
        prevBtn:SetPoint("LEFT", nav, "LEFT", 14, 0)
        prevBtn:SetScript("OnClick", function() self:GoToPrev() end)
        prevBtn:Hide()
        f.prevBtn = prevBtn

        -- Skip setup: finishes with the defaults, same end state as
        -- Finish, so the wizard does not come back by itself. Hidden on
        -- the last step, where Finish is the same thing.
        local skipBtn = MakeButton(nav, RCL["Skip setup"], 28)
        skipBtn:SetWidth(100)
        skipBtn:SetPoint("LEFT", prevBtn, "RIGHT", 8, 0)
        skipBtn:SetScript("OnClick", function()
            if RC.db and RC.db.setupWizard then
                RC.db.setupWizard.completed = true
                RC:SaveConfigurationToProfile()
            end
            f:Hide()
            RC:Print(RCL["Setup skipped - the defaults are on. |cffffd700/rc|r opens the settings; |cffffd700/rc tutorial|r shows you around."])
        end)
        f.skipBtn = skipBtn

        local stepCount = MakeFontString(nav, 11, "")
        stepCount:SetPoint("CENTER", nav, "CENTER", 0, 0)
        stepCount:SetTextColor(C("text","gray").r, C("text","gray").g, C("text","gray").b, 1)
        f.stepCountText = stepCount

        local nextBtn = MakeButton(nav, "Next >", 28)
        nextBtn:SetWidth(110)
        nextBtn:SetPoint("RIGHT", nav, "RIGHT", -14, 0)
        nextBtn:SetScript("OnClick", function() self:GoToNext() end)
        f.nextBtn = nextBtn

        self:ShowStep(self.currentStep)

        local grip = RC.UI:AttachResizeGrip(f, {
            minW = MIN_W, minH = MIN_H, maxW = MAX_W, maxH = MAX_H,
            onResize = function(frm, newW)
                if frm.stepBar then
                    Wizard:BuildStepDots(frm.stepBar, newW)
                    Wizard:UpdateStepDots(Wizard.currentStep)
                end
            end,
        })
        grip:HookScript("OnMouseUp", function()
            if RC.db and RC.db.setupWizard then
                RC.db.setupWizard.width  = math.floor(f:GetWidth())
                RC.db.setupWizard.height = math.floor(f:GetHeight())
                RC:SaveConfigurationToProfile()
            end
        end)

        local sw = RC.db.setupWizard
        if sw and sw.width and sw.height then
            f:SetSize(
                math.max(MIN_W, math.min(MAX_W, sw.width)),
                math.max(MIN_H, math.min(MAX_H, sw.height))
            )
        end

        f:Show()
        f:Raise()
    end

    -- Step indicator: a row of small flat tiles joined by hairlines. Each
    -- tile is a bordered box like every other piece of furniture, so the
    -- three states read the framework's way - pending is a plain button
    -- face, done is the configured-green marker, and the current step is
    -- the active look: green configuredBackground fill inside a muted
    -- green ring. Never a gold fill, and never a gold ring on green.
    local function PaintStepDot(dot, state)
        local fill, ring, ringA
        if state == "current" then
            fill, ring, ringA = C("buttons", "configuredBackground"), C("ui", "borderSelected"), 1
        elseif state == "done" then
            fill, ring, ringA = C("ui", "configured"), C("ui", "borderNormal"), 1
        else
            fill, ring, ringA = C("buttons", "normalBackground"), C("ui", "borderNormal"), 1
        end
        dot.bg:SetVertexColor(fill.r, fill.g, fill.b, state == "done" and 0.9 or (fill.a or 1))
        if dot.border and RC.UI and RC.UI.UpdateBorderColor then
            RC.UI:UpdateBorderColor(dot.border, ring, ringA)
        end
    end

    function Wizard:BuildStepDots(bar, frameW)
        -- Tiles and lines are pooled by index and only repositioned on
        -- rebuild (this runs on every OnSizeChanged tick while the resize
        -- grip is dragged, so creating new frames here would leak them).
        bar.dots  = bar.dots  or {}
        bar.lines = bar.lines or {}

        local total   = #steps
        local dotSize = 10
        local spacing = 22
        local totalW  = total * dotSize + (total - 1) * (spacing - dotSize)
        local fw      = frameW or (self.frame and self.frame:GetWidth()) or MIN_W
        local startX  = (fw - totalW) / 2
        local lineC   = C("buttons", "hoverBackground")

        for i = 1, total do
            local dot = bar.dots[i]
            if not dot then
                dot = CreateFrame("Frame", nil, bar)
                dot:SetSize(dotSize, dotSize)
                dot.bg = dot:CreateTexture(nil, "BACKGROUND")
                dot.bg:SetAllPoints()
                dot.bg:SetTexture(FLAT)
                if RC.UI and RC.UI.CreateSimpleBorder then
                    dot.border = RC.UI:CreateSimpleBorder(dot)
                end
                bar.dots[i] = dot
            end
            dot:ClearAllPoints()
            dot:SetPoint("CENTER", bar, "LEFT", startX + (i-1)*spacing + dotSize/2, 0)
            PaintStepDot(dot, "pending")
            dot:Show()
            if i < total then
                local line = bar.lines[i]
                if not line then
                    line = bar:CreateTexture(nil, "BACKGROUND")
                    line:SetHeight(1)
                    line:SetTexture(FLAT)
                    bar.lines[i] = line
                end
                line:ClearAllPoints()
                line:SetPoint("LEFT",  dot, "RIGHT", 0, 0)
                line:SetPoint("RIGHT", bar, "LEFT",  startX + i*spacing, 0)
                line:SetVertexColor(lineC.r, lineC.g, lineC.b, 1)
                line:Show()
            end
        end

        for i = total + 1, #bar.dots do bar.dots[i]:Hide() end
        for i = total, #bar.lines do bar.lines[i]:Hide() end
    end

    function Wizard:UpdateStepDots(cur)
        local bar = self.frame and self.frame.stepBar
        if not bar or not bar.dots then return end
        for i = 1, #steps do
            local dot = bar.dots[i]
            if dot then
                if     i == cur then PaintStepDot(dot, "current")
                elseif i <  cur then PaintStepDot(dot, "done")
                else                 PaintStepDot(dot, "pending") end
            end
        end
    end

    function Wizard:ShowStep(idx)
        if not self.frame then return end
        local f = self.frame
        idx = math.max(1, math.min(idx, #steps))
        self.currentStep = idx

        -- Saved on every step view, independent of Finish - this is what
        -- lets the wizard resume where the user left off, and what the
        -- account-wide auto-open check (Core_Scan) reads to avoid
        -- re-prompting someone who only got partway through.
        if RC.db and RC.db.setupWizard then
            RC.db.setupWizard.lastStep = idx
            RC:SaveConfigurationToProfile()
        end

        if f.activeContent then
            f.activeContent:Hide()
            f.activeContent = nil
        end

        -- One pooled container per step index: built on first visit, then
        -- shown/hidden instead of abandoning frames on every step change.
        -- Checkbox widgets persist their own state (they write straight to
        -- RC.db on click); steps needing fresh data expose RefreshOnShow.
        local step = steps[idx]
        f.stepContainers = f.stepContainers or {}
        local container = f.stepContainers[idx]
        if not container then
            container = CreateFrame("Frame", nil, f.content)
            container:SetAllPoints(f.content)
            f.stepContainers[idx] = container
            if step and step.build then step.build(container) end
        end
        if container.RefreshOnShow then container.RefreshOnShow() end
        container:Show()
        f.activeContent = container

        if f.titleText and step then
            f.titleText:SetText(RCL["Setup Wizard  -  "] .. (step.title or ""))
            f.titleText:SetTextColor(C("ui","headerText").r, C("ui","headerText").g, C("ui","headerText").b, 1)
        end

        if f.stepCountText then
            f.stepCountText:SetText(RCL["Step "] .. idx .. RCL[" of "] .. #steps)
            f.stepCountText:SetTextColor(C("text","gray").r, C("text","gray").g, C("text","gray").b, 1)
        end

        self:UpdateStepDots(idx)

        if f.prevBtn then
            if idx == 1 then
                f.prevBtn:Hide()
            else
                f.prevBtn:Show()
                f.prevBtn.text:SetText(RCL["< Previous"])
                f.prevBtn:Repaint()
            end
        end
        if f.skipBtn then
            f.skipBtn:ClearAllPoints()
            if idx == 1 then
                f.skipBtn:SetPoint("LEFT", f.nav, "LEFT", 14, 0)
            else
                f.skipBtn:SetPoint("LEFT", f.prevBtn, "RIGHT", 8, 0)
            end
            if idx == #steps then f.skipBtn:Hide() else f.skipBtn:Show() end
        end

        -- Finish wears the button's active look (green fill, gold ring)
        -- rather than a gold fill of its own; the styled button repaints
        -- every other state from the theme itself.
        self:RefreshNextButton()
    end

    -- Finish wears the button's active look (green fill, gold ring)
    -- rather than a gold fill of its own; the styled button repaints
    -- every other state from the theme itself.
    function Wizard:RefreshNextButton()
        local f = self.frame
        if not (f and f.nextBtn) then return end
        if self.currentStep == #steps then
            f.nextBtn.text:SetText(RCL["Finish & tour"])
            f.nextBtn:SetActive(true)
        else
            f.nextBtn.text:SetText(RCL["Next >"])
            f.nextBtn:SetActive(false)
        end
    end

    function Wizard:GoToNext()
        if self.currentStep < #steps then
            self:ShowStep(self.currentStep + 1)
        else
            -- Only path that sets completed=true. Closing the window any
            -- other way (Esc, X, /reload) leaves completed=false but keeps
            -- every setting already toggled - aborting loses nothing except
            -- the "don't auto-open again" signal.
            if RC.db and RC.db.setupWizard then
                RC.db.setupWizard.completed = true
                RC:SaveConfigurationToProfile()
            end
            if self.frame then self.frame:Hide() end
            self:FinishIntoSettings()
        end
    end

    -- The second half of the first run: the settings window opens and
    -- the tour starts in it. The X on the tour's callout is the way out.
    function Wizard:FinishIntoSettings()
        if not (RC.sidebarConfigFrame and RC.sidebarConfigFrame:IsShown()) and RC.CreateSidebarConfigWindow then
            RC:CreateSidebarConfigWindow()
        end
        C_Timer.After(0.5, function()
            if RC.Tutorial and not RC.Tutorial.active then RC.Tutorial:Start("wizard") end
        end)
    end

    function Wizard:GoToPrev()
        if self.currentStep > 1 then self:ShowStep(self.currentStep - 1) end
    end

end

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
if IsLoggedIn() then
    -- Already logged in: the event will never be needed, so drop the
    -- registration instead of leaving a live listener with no handler.
    initFrame:UnregisterEvent("PLAYER_LOGIN")
    InitializeSetupWizard()
else
    initFrame:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_LOGIN" then
            self:UnregisterEvent("PLAYER_LOGIN")
            C_Timer.After(0.5, InitializeSetupWizard)
        end
    end)
end
