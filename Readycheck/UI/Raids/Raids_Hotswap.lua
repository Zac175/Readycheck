------------------------------------------------------------------------
-- Readycheck - Hotswap Macro Builder & Docs
-- Also NOT raid-profile data: settings live under self.db.hotswap* (global/
-- character-level) and the whole feature keys off gear sets named EXACTLY
-- "Battle Shout" / "Diamond Flask" plus a shirt-slot on/off flag - there is
-- no raid selection here, so no remote-edit branching applies. This page
-- is mostly static documentation text (see Overview tab) plus a macro
-- text generator; the /equipslot builder below is the only part with real
-- logic (macro slot bookkeeping).
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)
local GetSpellInfo = GetSpellInfo or (RCC and RCC.Compat and RCC.Compat.GetSpellInfo)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local table_insert, table_remove, table_sort = table.insert, table.remove, table.sort
local string_format, string_lower = string.format, string.lower
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local RC = _G.Readycheck
if not (RC and RC.UI) then return end
RC._sbr = RC._sbr or {}
local _sbr = RC._sbr
local TEXT = _sbr.TEXT
    function RC:ShowSidebarHotswapMacros(frame, preserveScroll)
        local cardY
        self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
        local parent = frame.scrollChild
        local yPos = -20

        local headerFrame, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Hotswap Macros"],
            RCL["T2 set bonus gear swapping for Battle Shout"], "Interface\\Icons\\INV_Helmet_71")
        yPos = newY

        -- Hotswap draws nothing on screen (macros and chat lines only), so
        -- the page has no preview. "settings" (search aliases) is Behavior.
        if RC.hotswapTab == "settings" then RC.hotswapTab = "behavior" end
        RC.hotswapTab = RC.hotswapTab or "overview"
        local hotswapTabs = {
            { "overview", RCL["Overview"] },
            { "macros",   RCL["Macros"]   },
            { "behavior", RCL["Behavior"] },
        }
        yPos = self:BuildSettingsTabBar(parent, yPos, hotswapTabs, RC.hotswapTab, function(k)
            RC.hotswapTab = k
            RC:ShowSidebarHotswapMacros(frame, true)
        end)

        if RC.hotswapTab == "overview" then
        local _gold = RC:GetColor("ui", "accentGold") or {r=0.85,g=0.65,b=0.25}

        local infoCard = self:CreateSettingsCard(parent, yPos, RCL["What is hotswap"])
        local cardY = -35

        local infoText = self:CreateFontString(infoCard, "OVERLAY", nil, 11)
        infoText:SetPoint("TOPLEFT",  infoCard, "TOPLEFT",   15, cardY)
        infoText:SetPoint("TOPRIGHT", infoCard, "TOPRIGHT", -15, cardY)
        infoText:SetJustifyH("LEFT")
        infoText:SetText(RCL["Hotswap temporarily equips a buff-optimized gear set, fires an ability or /use, and then your normal set restores your regular gear. Runs OUT OF COMBAT ONLY. If party members are in combat nearby the swap is held back (T2 protection)."])
        infoText:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
        infoText:SetWordWrap(true)
        cardY = cardY - (infoText:GetStringHeight() or 12) - 10

        infoCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - infoCard:GetHeight() - 15

        local shirtCard = self:CreateSettingsCard(parent, yPos, RCL["How the shirt slot detection works"])
        cardY = -35

        local shirtExp = self:CreateFontString(shirtCard, "OVERLAY", nil, 11)
        shirtExp:SetPoint("TOPLEFT",  shirtCard, "TOPLEFT",   15, cardY)
        shirtExp:SetPoint("TOPRIGHT", shirtCard, "TOPRIGHT", -15, cardY)
        shirtExp:SetJustifyH("LEFT")
        shirtExp:SetText(RCL["The macros use an [equipped:Shirt] conditional to know whether your boost set is currently on. It doesn't matter what the shirt is - any shirt in the slot counts. The important pair is:"])
        shirtExp:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
        shirtExp:SetWordWrap(true)
        cardY = cardY - (shirtExp:GetStringHeight() or 12) - 10

        local shirtPair = {
            "- Boost set (named 'Battle Shout' or 'Diamond Flask') has a shirt equipped in the shirt slot.",
            "- Normal set (any name) leaves the shirt slot empty - it unequips the shirt.",
        }
        for _, t in ipairs(shirtPair) do
            local line = self:CreateFontString(shirtCard, "OVERLAY", nil, 11)
            line:SetPoint("TOPLEFT",  shirtCard, "TOPLEFT",   25, cardY)
            line:SetPoint("TOPRIGHT", shirtCard, "TOPRIGHT", -15, cardY)
            line:SetJustifyH("LEFT")
            line:SetText(t)
            line:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            line:SetWordWrap(true)
            cardY = cardY - (line:GetStringHeight() or 12) - 6
        end
        cardY = cardY - 6

        shirtCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - shirtCard:GetHeight() - 15

        local nameCard = self:CreateSettingsCard(parent, yPos, RCL["Set naming - must match exactly"])
        cardY = -35

        local nameExp = self:CreateFontString(nameCard, "OVERLAY", nil, 11)
        nameExp:SetPoint("TOPLEFT",  nameCard, "TOPLEFT",   15, cardY)
        nameExp:SetPoint("TOPRIGHT", nameCard, "TOPRIGHT", -15, cardY)
        nameExp:SetJustifyH("LEFT")
        nameExp:SetText(RCL["The hotswap code looks up your boost sets by name, so the boost sets must be named EXACTLY:"])
        nameExp:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
        nameExp:SetWordWrap(true)
        cardY = cardY - (nameExp:GetStringHeight() or 12) - 10

        -- each boost set with its icon, and whether you have made it yet
        local GMx = RC.GearManager
        local names = {}
        for _, e in ipairs({
            { "Battle Shout",  RCL["(boost set - 3 pieces of Wrath plus a shirt)"] },
            { "Diamond Flask", RCL["(boost set - healing gear / weapon plus a shirt with the flask in the shirt slot)"] },
        }) do
            local have = GMx and GMx.sets and GMx.sets[e[1]] ~= nil
            names[#names + 1] = RC:GetGearSetIconText(e[1], 14) .. " '" .. e[1] .. "' " .. e[2]
                .. (have and RCL[" - you have it"] or RCL[" - not made yet"])
        end
        for _, t in ipairs(names) do
            local line = self:CreateFontString(nameCard, "OVERLAY", nil, 11)
            line:SetPoint("TOPLEFT",  nameCard, "TOPLEFT",   25, cardY)
            line:SetPoint("TOPRIGHT", nameCard, "TOPRIGHT", -15, cardY)
            line:SetJustifyH("LEFT")
            line:SetText(t)
            line:SetTextColor(_gold.r, _gold.g, _gold.b, 1)
            line:SetWordWrap(true)
            cardY = cardY - (line:GetStringHeight() or 12) - 6
        end
        cardY = cardY - 4

        local normalExp = self:CreateFontString(nameCard, "OVERLAY", nil, 11)
        normalExp:SetPoint("TOPLEFT",  nameCard, "TOPLEFT",   15, cardY)
        normalExp:SetPoint("TOPRIGHT", nameCard, "TOPRIGHT", -15, cardY)
        normalExp:SetJustifyH("LEFT")
        normalExp:SetText(RCL["Your normal (post-swap) gear set can be named anything - 'DPS', 'Main', 'Raid', whatever. The only requirement is that it unequips the shirt slot so the [equipped:Shirt] conditional goes false when it's active."])
        normalExp:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
        normalExp:SetWordWrap(true)
        cardY = cardY - (normalExp:GetStringHeight() or 12) - 10

        nameCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - nameCard:GetHeight() - 15

        local contentsCard = self:CreateSettingsCard(parent, yPos, RCL["What goes in each boost set"])
        cardY = -35

        local bsHdr = self:CreateFontString(contentsCard, "OVERLAY", nil, 11)
        bsHdr:SetPoint("TOPLEFT", contentsCard, "TOPLEFT", 15, cardY)
        bsHdr:SetText(RCL["Battle Shout:"])
        bsHdr:SetTextColor(_gold.r, _gold.g, _gold.b, 1)
        cardY = cardY - 18

        local bsBody = self:CreateFontString(contentsCard, "OVERLAY", nil, 11)
        bsBody:SetPoint("TOPLEFT",  contentsCard, "TOPLEFT",   25, cardY)
        bsBody:SetPoint("TOPRIGHT", contentsCard, "TOPRIGHT", -15, cardY)
        bsBody:SetJustifyH("LEFT")
        bsBody:SetText(RCL["3 pieces of Wrath for the set bonus, plus any shirt in the shirt slot. The shirt is just the detection flag - it doesn't need to grant any stats."])
        bsBody:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
        bsBody:SetWordWrap(true)
        cardY = cardY - (bsBody:GetStringHeight() or 12) - 10

        local dfHdr = self:CreateFontString(contentsCard, "OVERLAY", nil, 11)
        dfHdr:SetPoint("TOPLEFT", contentsCard, "TOPLEFT", 15, cardY)
        dfHdr:SetText(RCL["Diamond Flask:"])
        dfHdr:SetTextColor(_gold.r, _gold.g, _gold.b, 1)
        cardY = cardY - 18

        local dfBody = self:CreateFontString(contentsCard, "OVERLAY", nil, 11)
        dfBody:SetPoint("TOPLEFT",  contentsCard, "TOPLEFT",   25, cardY)
        dfBody:SetPoint("TOPRIGHT", contentsCard, "TOPRIGHT", -15, cardY)
        dfBody:SetJustifyH("LEFT")
        dfBody:SetText(RCL["Healing gear and healing weapon(s) to boost the flask snapshot, plus any shirt in the shirt slot. Diamond Flask scales with healing power at the moment you /use it, so the inflated healing gives you a stronger on-use buff that persists after the swap-back."])
        dfBody:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
        dfBody:SetWordWrap(true)
        cardY = cardY - (dfBody:GetStringHeight() or 12) - 10

        contentsCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - contentsCard:GetHeight() - 15

        do
            local previewBase = "Interface\\AddOns\\Readycheck\\Media\\GearPreviews\\"

            local previews = {
                { label = RCL["Normal Set"],    setRef = "DPS",                          file = "normgear.tga"     },
                { label = RCL["Battle Shout"],  setRef = "Battle Shout",                 file = "battleshout.tga"  },
                { label = RCL["Diamond Flask"], setRef = "Diamond Flask",                file = "diamondflask.tga" },
            }

            local examplesCard = self:CreateSettingsCard(parent, yPos, RCL["Example setups"])
            local exY = -35

            local cardW   = examplesCard:GetWidth()
            local margin  = 30
            local gap     = 16
            local count   = #previews
            local maxThumb, minThumb = 180, 110
            local thumbSize = math.floor((cardW - margin - gap * (count - 1)) / count)
            if thumbSize > maxThumb then thumbSize = maxThumb end
            if thumbSize < minThumb then thumbSize = minThumb end

            local rowW   = thumbSize * count + gap * (count - 1)
            local startX = math.floor((cardW - rowW) / 2)

            for i, p in ipairs(previews) do
                local xOff = startX + (i - 1) * (thumbSize + gap)

                local lbl = self:CreateFontString(examplesCard, "OVERLAY", nil, 11)
                lbl:SetPoint("TOPLEFT", examplesCard, "TOPLEFT", xOff, exY)
                lbl:SetWidth(thumbSize)
                lbl:SetJustifyH("CENTER")
                lbl:SetText(p.label)
                lbl:SetTextColor(_gold.r, _gold.g, _gold.b, 1)

                local sub = self:CreateFontString(examplesCard, "OVERLAY", nil, 10)
                sub:SetPoint("TOPLEFT", examplesCard, "TOPLEFT", xOff, exY - 16)
                sub:SetWidth(thumbSize)
                sub:SetJustifyH("CENTER")
                sub:SetText(RCL["set: \""] .. p.setRef .. "\"")
                sub:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])

                local thumb = examplesCard:CreateTexture(nil, "ARTWORK")
                thumb:SetSize(thumbSize, thumbSize)
                thumb:SetPoint("TOPLEFT", examplesCard, "TOPLEFT", xOff, exY - 34)
                thumb:SetTexture(previewBase .. p.file)
            end
            exY = exY - thumbSize - 42

            examplesCard:SetContentHeight(math.abs(exY))
            yPos = yPos - examplesCard:GetHeight() - 15
        end

        local pitCard = self:CreateSettingsCard(parent, yPos, RCL["Common pitfalls"])
        cardY = -35

        local pitfalls = {
            "- If your normal set does NOT unequip the shirt slot, the shirt stays on after the ability fires. The [equipped:Shirt] conditional then stays TRUE and the next press of the macro does nothing.",
            "- Boost set names must match EXACTLY: 'Battle Shout' and 'Diamond Flask'. Case and spacing count.",
            "- Hotswap only handles these two gear pairs. It will not cycle two trinkets or swap weapons on its own. Use the trinket auto-swap system for trinkets.",
            "- It runs out of combat only. In combat the press is blocked and your combat message is printed - or, with Queue In Combat on (Settings tab), it waits and swaps by itself when combat ends.",
        }
        for _, pitText in ipairs(pitfalls) do
            local line = self:CreateFontString(pitCard, "OVERLAY", nil, 11)
            line:SetPoint("TOPLEFT",  pitCard, "TOPLEFT",   25, cardY)
            line:SetPoint("TOPRIGHT", pitCard, "TOPRIGHT", -15, cardY)
            line:SetJustifyH("LEFT")
            line:SetText(pitText)
            line:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            line:SetWordWrap(true)
            cardY = cardY - (line:GetStringHeight() or 12) - 6
        end
        cardY = cardY - 6

        pitCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - pitCard:GetHeight() - 15

        elseif RC.hotswapTab == "macros" then
        local _gold = RC:GetColor("ui", "accentGold") or {r=0.85,g=0.65,b=0.25}

        local reminderCard = self:CreateSettingsCard(parent, yPos, RCL["Before you copy"])
        cardY = -35
        local reminder = self:CreateFontString(reminderCard, "OVERLAY", nil, 11)
        reminder:SetPoint("TOPLEFT",  reminderCard, "TOPLEFT",   15, cardY)
        reminder:SetPoint("TOPRIGHT", reminderCard, "TOPRIGHT", -15, cardY)
        reminder:SetJustifyH("LEFT")
        reminder:SetText(RCL["Make sure your gear sets are set up first - see the Overview tab. Boost sets must be named EXACTLY 'Battle Shout' and 'Diamond Flask', each with a shirt in the shirt slot. Your normal set (any name) must unequip the shirt."])
        reminder:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
        reminder:SetWordWrap(true)
        cardY = cardY - (reminder:GetStringHeight() or 12) - 10
        reminderCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - reminderCard:GetHeight() - 15

        local bshoutCard = self:CreateSettingsCard(parent, yPos, RCL["Battle Shout macro"])
        cardY = -35

        local bshoutBlurb = self:CreateFontString(bshoutCard, "OVERLAY", nil, 11)
        bshoutBlurb:SetPoint("TOPLEFT",  bshoutCard, "TOPLEFT",   15, cardY)
        bshoutBlurb:SetPoint("TOPRIGHT", bshoutCard, "TOPRIGHT", -15, cardY)
        bshoutBlurb:SetJustifyH("LEFT")
        bshoutBlurb:SetText(RCL["Requires a gear set named 'Battle Shout' with 3 pieces of Wrath and a shirt in the shirt slot, plus a normal set that unequips the shirt."])
        bshoutBlurb:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
        bshoutBlurb:SetWordWrap(true)
        cardY = cardY - (bshoutBlurb:GetStringHeight() or 12) - 8

        local bshoutLabel = self:CreateFontString(bshoutCard, "OVERLAY", nil, 10)
        bshoutLabel:SetPoint("TOPLEFT", bshoutCard, "TOPLEFT", 15, cardY)
        bshoutLabel:SetText(RCL["Click inside, Ctrl+A to select all, Ctrl+C to copy:"])
        bshoutLabel:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
        cardY = cardY - 20

        local bshoutMacroText = "#showtooltip Battle Shout\n/run Readycheck:HotswapBattleShout()\n/cast [combat] Battle Shout\n/cast [equipped:Shirt] Battle Shout\n/cancelaura Bloodrage"
        local bshoutEditContainer = self.UI:CreateStyledEditBox(bshoutCard, {
            multiLine   = true,
            readOnly    = true,
            initialText = bshoutMacroText,
        })
        bshoutEditContainer:SetPoint("TOPLEFT",  bshoutCard, "TOPLEFT",  15, cardY)
        bshoutEditContainer:SetPoint("TOPRIGHT", bshoutCard, "TOPRIGHT", -15, cardY)
        bshoutEditContainer:SetHeight(70)
        local bshoutEdit = bshoutEditContainer.editBox
        cardY = cardY - 80

        bshoutCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - bshoutCard:GetHeight() - 15

        local flaskCard = self:CreateSettingsCard(parent, yPos, RCL["Diamond Flask macro"])
        cardY = -35

        local flaskBlurb = self:CreateFontString(flaskCard, "OVERLAY", nil, 11)
        flaskBlurb:SetPoint("TOPLEFT",  flaskCard, "TOPLEFT",   15, cardY)
        flaskBlurb:SetPoint("TOPRIGHT", flaskCard, "TOPRIGHT", -15, cardY)
        flaskBlurb:SetJustifyH("LEFT")
        flaskBlurb:SetText(RCL["Requires a gear set named 'Diamond Flask' with healing gear, healing weapon, and a shirt in the shirt slot (Diamond Flask scales with healing power at /use time). Your normal set must unequip the shirt."])
        flaskBlurb:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
        flaskBlurb:SetWordWrap(true)
        cardY = cardY - (flaskBlurb:GetStringHeight() or 12) - 8

        local flaskLabel = self:CreateFontString(flaskCard, "OVERLAY", nil, 10)
        flaskLabel:SetPoint("TOPLEFT", flaskCard, "TOPLEFT", 15, cardY)
        flaskLabel:SetText(RCL["Click inside, Ctrl+A to select all, Ctrl+C to copy:"])
        flaskLabel:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
        cardY = cardY - 20

        local flaskMacroText = "#showtooltip Diamond Flask\n/run Readycheck:HotswapDiamondFlask()\n/cast [combat] Diamond Flask\n/use [equipped:Shirt] Diamond Flask"
        local flaskEditContainer = self.UI:CreateStyledEditBox(flaskCard, {
            multiLine   = true,
            readOnly    = true,
            initialText = flaskMacroText,
        })
        flaskEditContainer:SetPoint("TOPLEFT",  flaskCard, "TOPLEFT",  15, cardY)
        flaskEditContainer:SetPoint("TOPRIGHT", flaskCard, "TOPRIGHT", -15, cardY)
        flaskEditContainer:SetHeight(60)
        local flaskEdit = flaskEditContainer.editBox
        cardY = cardY - 70

        flaskCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - flaskCard:GetHeight() - 15

        local equipCard = self:CreateSettingsCard(parent, yPos, RCL["Equip item to slot"])
        cardY = -35

        local equipBlurb = self:CreateFontString(equipCard, "OVERLAY", nil, 11)
        equipBlurb:SetPoint("TOPLEFT",  equipCard, "TOPLEFT",   15, cardY)
        equipBlurb:SetPoint("TOPRIGHT", equipCard, "TOPRIGHT", -15, cardY)
        equipBlurb:SetJustifyH("LEFT")
        equipBlurb:SetText(RCL["Builds a /equipslot macro that swaps one specific item into one slot. Drag the new macro onto an action bar and press that button (or bind the slot under Esc > Key Bindings) to fire it. Weapons swap in combat; trinkets and armor only swap out of combat."])
        equipBlurb:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
        equipBlurb:SetWordWrap(true)
        cardY = cardY - (equipBlurb:GetStringHeight() or 12) - 12

        RC._rcEquipSlot = RC._rcEquipSlot or 13

        local equipItemLabel = self:CreateFontString(equipCard, "OVERLAY", nil, 10)
        equipItemLabel:SetPoint("TOPLEFT", equipCard, "TOPLEFT", 15, cardY)
        equipItemLabel:SetText(RCL["Item name (exact):"])
        equipItemLabel:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
        cardY = cardY - 20

        local equipItemContainer = self.UI:CreateStyledEditBox(equipCard, {
            height      = 24,
            maxLetters  = 60,
            initialText = RC._rcEquipItemName or "",
        })
        equipItemContainer:SetPoint("TOPLEFT",  equipCard, "TOPLEFT",  15, cardY)
        equipItemContainer:SetPoint("TOPRIGHT", equipCard, "TOPRIGHT", -15, cardY)
        equipItemContainer:SetHeight(24)
        local equipItemEdit = equipItemContainer.editBox
        cardY = cardY - 36

        local equipSlotLabel = self:CreateFontString(equipCard, "OVERLAY", nil, 10)
        equipSlotLabel:SetPoint("TOPLEFT", equipCard, "TOPLEFT", 15, cardY)
        equipSlotLabel:SetText(RCL["Slot:"])
        equipSlotLabel:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])

        local equipSlots = {
            { text = RCL["Trinket 1"], value = 13 },
            { text = RCL["Trinket 2"], value = 14 },
            { text = RCL["Main Hand"], value = 16 },
            { text = RCL["Off Hand"],  value = 17 },
            { text = RCL["Ranged"],    value = 18 },
            { text = RCL["Head"],      value = 1  },
            { text = RCL["Neck"],      value = 2  },
            { text = RCL["Shoulder"],  value = 3  },
            { text = RCL["Back"],      value = 15 },
            { text = RCL["Chest"],     value = 5  },
            { text = RCL["Wrist"],     value = 9  },
            { text = RCL["Hands"],     value = 10 },
            { text = RCL["Waist"],     value = 6  },
            { text = RCL["Legs"],      value = 7  },
            { text = RCL["Feet"],      value = 8  },
            { text = RCL["Finger 1"],  value = 11 },
            { text = RCL["Finger 2"],  value = 12 },
        }
        local function _equipSlotName(v)
            for _, o in ipairs(equipSlots) do if o.value == v then return o.text end end
            return "Trinket 1"
        end
        local equipSlotDD = self.UI:CreateScrollableDropdown(equipCard, 130, _equipSlotName(RC._rcEquipSlot), 10)
        equipSlotDD:SetPoint("TOPLEFT", equipCard, "TOPLEFT", 70, cardY + 5)
        equipSlotDD:SetItems(equipSlots, function(value)
            RC._rcEquipSlot = value
        end)
        cardY = cardY - 36

        local equipOutLabel = self:CreateFontString(equipCard, "OVERLAY", nil, 10)
        equipOutLabel:SetPoint("TOPLEFT", equipCard, "TOPLEFT", 15, cardY)
        equipOutLabel:SetText(RCL["Macro body:"])
        equipOutLabel:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
        cardY = cardY - 20

        local equipOutContainer = self.UI:CreateStyledEditBox(equipCard, {
            multiLine   = true,
            readOnly    = true,
            initialText = "/equipslot " .. tostring(RC._rcEquipSlot) .. " " .. (RC._rcEquipItemName or ""),
        })
        equipOutContainer:SetPoint("TOPLEFT",  equipCard, "TOPLEFT",  15, cardY)
        equipOutContainer:SetPoint("TOPRIGHT", equipCard, "TOPRIGHT", -15, cardY)
        equipOutContainer:SetHeight(30)
        local equipOut = equipOutContainer.editBox
        cardY = cardY - 40

        local equipCreateBtn = self.UI:CreateStyledButton(equipCard, RCL["Create WoW Macro"], 150, 24)
        equipCreateBtn:SetPoint("TOPLEFT", equipCard, "TOPLEFT", 15, cardY)
        equipCreateBtn:SetScript("OnClick", function()
            local itemName = (equipItemEdit:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
            local slotId = RC._rcEquipSlot or 13
            if itemName == "" then
                if equipOut then equipOut:SetText(RCL["Enter an item name first."]) end
                return
            end
            RC._rcEquipItemName = itemName
            local body = "/equipslot " .. slotId .. " " .. itemName
            if equipOut then equipOut:SetText(body) end
            -- Account-wide macro slots are 1-120, character-specific slots
            -- are 121-138 (WoW's fixed layout); an existing macro with the
            -- same name is edited in place instead of duplicated.
            local mName = itemName:sub(1, 16)
            local mIcon = "INV_Misc_QuestionMark"
            local gCount, cCount = GetNumMacros()
            local existIdx = nil
            for i = 1, gCount do if (GetMacroInfo(i)) == mName then existIdx = i; break end end
            if not existIdx then
                for i = 121, 120 + cCount do if (GetMacroInfo(i)) == mName then existIdx = i; break end end
            end
            if existIdx then EditMacro(existIdx, mName, mIcon, body)
            elseif gCount < 120 then CreateMacro(mName, mIcon, body, nil)
            elseif cCount < 18  then CreateMacro(mName, mIcon, body, 1) end
        end)
        cardY = cardY - 32

        equipCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - equipCard:GetHeight() - 15

        elseif RC.hotswapTab == "behavior" then
        local settingsCard = self:CreateSettingsCard(parent, yPos, RCL["Hotswap"])
        cardY = -35

        local hotswapEnabled = self.db.hotswapEnabled ~= false
        local hotswapCheck = self.UI:CreateSettingCheckbox(settingsCard, cardY, "Enable Hotswap System", hotswapEnabled, function(cb)
            local newState = cb:GetChecked()
            RC.db.hotswapEnabled = newState
            if RC.Hotswap then RC.Hotswap.enabled = newState end
            RC:ForceCheckboxUpdate(cb, newState)
            RC:SaveConfigurationToProfile()
        end)
        cardY = cardY - 28
        local hotswapMark = self.UI:MarkCard(settingsCard)

        local combatQueue = self.db.hotswapCombatQueue == true
        local queueCheck = self.UI:CreateSettingCheckbox(settingsCard, cardY, "Queue In Combat (swap when combat ends)", combatQueue, function(cb)
            local newState = cb:GetChecked()
            RC.db.hotswapCombatQueue = newState
            -- through the setter, so the queue markers come off with it
            if not newState and RC.Hotswap and RC.Hotswap.SetCombatQueue then
                RC.Hotswap:SetCombatQueue(nil)
            end
            RC:ForceCheckboxUpdate(cb, newState)
            RC:SaveConfigurationToProfile()
        end)
        cardY = cardY - 24

        local queueHint = self:CreateFontString(settingsCard, "OVERLAY", nil, 11)
        queueHint:SetPoint("TOPLEFT",  settingsCard, "TOPLEFT",   25, cardY)
        queueHint:SetPoint("TOPRIGHT", settingsCard, "TOPRIGHT", -15, cardY)
        queueHint:SetJustifyH("LEFT")
        queueHint:SetText(RCL["Press a hotswap macro in combat and the swap is remembered instead of refused. When combat ends the boost set goes on by itself and you have 5 seconds to press the macro again; if you do not, your normal gear comes back."])
        queueHint:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
        queueHint:SetWordWrap(true)
        cardY = cardY - (queueHint:GetStringHeight() or 24) - 10

        local t2Protect = self.db.hotswapT2Protect ~= false
        local t2Check = self.UI:CreateSettingCheckbox(settingsCard, cardY, "T2 Protection (prevent equip if party in combat)", t2Protect, function(cb)
            local newState = cb:GetChecked()
            RC.db.hotswapT2Protect = newState
            RC:ForceCheckboxUpdate(cb, newState)
            RC:SaveConfigurationToProfile()
        end)
        cardY = cardY - 28

        local blockMsgLabel = self:CreateFontString(settingsCard, "OVERLAY", nil, 11)
        blockMsgLabel:SetPoint("TOPLEFT", settingsCard, "TOPLEFT", 25, cardY)
        blockMsgLabel:SetText(RCL["Block message (%player% = the offender's name):"])
        blockMsgLabel:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
        cardY = cardY - 20
        local blockMsgContainer = self.UI:CreateStyledEditBox(settingsCard, {
            height      = 22,
            initialText = self.db.hotswapCombatBlockMessage or "%player% in combat -- not equipping T2!",
            onTextChanged = function(s) RC.db.hotswapCombatBlockMessage = s:GetText() end,
            onFocusLost   = function() RC:SaveConfigurationToProfile() end,
        })
        blockMsgContainer:SetPoint("TOPLEFT",  settingsCard, "TOPLEFT",   25, cardY)
        blockMsgContainer:SetPoint("TOPRIGHT", settingsCard, "TOPRIGHT", -15, cardY)
        local blockMsgEdit = blockMsgContainer.editBox
        cardY = cardY - 32
        -- the block message is only sent with the protection on (already set in)
        self.UI:BindDependents(t2Check, { blockMsgLabel, blockMsgContainer }, { indent = 0 })

        local announceEnabled = self.db.hotswapPartyAnnounce or false
        local announceCheck = self.UI:CreateSettingCheckbox(settingsCard, cardY, "Enable Announcements", announceEnabled, function(cb)
            local newState = cb:GetChecked()
            RC.db.hotswapPartyAnnounce = newState
            RC:ForceCheckboxUpdate(cb, newState)
            RC:SaveConfigurationToProfile()
            RC:ShowSidebarHotswapMacros(frame, true)
        end)
        cardY = cardY - 30

        if announceEnabled then
            local channelLabel = self:CreateFontString(settingsCard, "OVERLAY", nil, 11)
            channelLabel:SetPoint("TOPLEFT", settingsCard, "TOPLEFT", 15, cardY)
            channelLabel:SetText(RCL["Announcement Channel:"])
            channelLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = cardY - 22

            local announceChannel = self.db.hotswapAnnounceChannel or "PARTY"
            local channelDropdown = self.UI:CreateScrollableDropdown(settingsCard, 120, RCL["Channel..."], 8)
            channelDropdown:SetPoint("TOPLEFT", settingsCard, "TOPLEFT", 15, cardY)
            do
                local channels = {"PARTY", "RAID", "SAY", "GUILD"}
                local channelItems = {}
                for _, channel in ipairs(channels) do
                    table.insert(channelItems, { text = channel, value = channel })
                end
                channelDropdown:SetItems(channelItems, function(value)
                    RC.db.hotswapAnnounceChannel = value
                    RC:SaveConfigurationToProfile()
                end)
                channelDropdown:SetSelectedValue(announceChannel, announceChannel)
            end
            cardY = cardY - 45

            local msgLabel = self:CreateFontString(settingsCard, "OVERLAY", nil, 11)
            msgLabel:SetPoint("TOPLEFT", settingsCard, "TOPLEFT", 15, cardY)
            msgLabel:SetText(RCL["Message (%player% = your name):"])
            msgLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = cardY - 22

            local announceMsg = self.db.hotswapAnnounceMessage or "%player% T2 Battle Shout"
            local msgEditContainer = self.UI:CreateStyledEditBox(settingsCard, {
                width       = 280, height = 22,
                initialText = announceMsg,
                onTextChanged = function(s) RC.db.hotswapAnnounceMessage = s:GetText() end,
                onFocusLost   = function() RC:SaveConfigurationToProfile() end,
            })
            msgEditContainer:SetPoint("TOPLEFT", settingsCard, "TOPLEFT", 15, cardY)
            local msgEdit = msgEditContainer.editBox
            cardY = cardY - 35
        end
        self.UI:BindDependents(hotswapCheck, self.UI:CardSince(settingsCard, hotswapMark))

        settingsCard:SetContentHeight(math.abs(cardY))

        yPos = yPos - settingsCard:GetHeight() - 15
        end

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
    end

