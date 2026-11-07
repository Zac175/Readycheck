------------------------------------------------------------------------
-- Readycheck - Smart Macro
-- Editor for per-macro condition/action rules that rewrite an in-game
-- macro body based on current target; RC.SmartMacro evaluates them live.
-- Settings live under RC.db.smartMacros (synced as "smartMacros" in
-- SidebarMeshSync.lua).
------------------------------------------------------------------------
local AddonName = "Readycheck"
local RC = _G[AddonName]

-- Forward-declared so the 'function SM_RenderList/Edit' definitions below
-- assign these file-locals instead of leaking globals into _G.
local SM_RenderList, SM_RenderEdit

local PAD    = 10
local ROW_H  = 28
local LBL_W  = 95
local COND_W = 165
local VAL_W  = 130

local COND_ITEMS = {
    { text = RCL["Default (no target)"],        value = "notarget"   },
    { text = RCL["Undead"],                     value = "undead"     },
    { text = RCL["Not Undead"],                 value = "notundead"  },
    { text = RCL["Name contains..."],           value = "named",     needsValue = true },
    { text = RCL["Specific Boss / Mob"],        value = "bossPicker", needsPicker = true },
    { text = RCL["World boss"],                 value = "boss"       },
    { text = RCL["Elite"],                      value = "elite"      },
    { text = RCL["Enemy"],                      value = "enemy"      },
    { text = RCL["Friendly"],                   value = "friendly"   },
    { text = RCL["Always (fires regardless)"],  value = "always"     },
}

local function CondLabel(condValue)
    for _, it in ipairs(COND_ITEMS) do
        if it.value == condValue then return it.text end
    end
    return "Select condition..."
end

local function CondNeedsValue(condValue)
    for _, it in ipairs(COND_ITEMS) do
        if it.value == condValue then return it.needsValue end
    end
    return false
end

local function CondNeedsPicker(condValue)
    for _, it in ipairs(COND_ITEMS) do
        if it.value == condValue then return it.needsPicker end
    end
    return false
end

local function GetBossPickerItems()
    local items = { { text = RCL["(type a custom name below)"], value = "" } }
    local raids = { "Naxxramas", "Ahn'Qiraj", "Blackwing Lair", "Molten Core" }
    -- another game version lists its own raids (RaidFlavor.lua)
    if RC._raidFlavorApplied then raids = RC:RaidNames() end
    local seen = {}
    for _, raid in ipairs(raids) do
        local cfg = RC.raidMobConfigs and RC.raidMobConfigs[raid]
        if cfg then
            local names = {}
            for bossName in pairs(cfg) do
                if not seen[bossName] then
                    seen[bossName] = true
                    names[#names + 1] = bossName
                end
            end
            table.sort(names)
            if #names > 0 then
                -- "__header__" is a non-selectable divider row; stripped out
                -- before the list is handed to the dropdown (see filteredItems below).
                items[#items + 1] = { text = "-- " .. raid .. " --", value = "__header__" }
                for _, name in ipairs(names) do
                    items[#items + 1] = { text = name, value = name }
                end
            end
        end
    end
    return items
end

local function GetRuleRaidScopeItems()
    local items = { { text = RCL["Any raid"], value = "any" } }
    for _, r in ipairs(RC.availableRaids or {}) do
        items[#items + 1] = { text = r, value = r }
    end
    return items
end

local function GetRuleProfileItems(raidName)
    local items = { { text = RCL["Any profile"], value = "any" } }
    local rp = RC.db and RC.db.raidProfiles and RC.db.raidProfiles[raidName]
    if rp and rp.profiles then
        local names = {}
        for name in pairs(rp.profiles) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            items[#items + 1] = { text = name, value = name }
        end
    end
    return items
end

local ACTION_ITEMS = {
    { text = RCL["/use  (item or spell)"], value = "use"  },
    { text = RCL["/cast (spell only)"],    value = "cast" },
}

local SM_Editor = { selectedId = nil }

local function MakeFS(parent, size, text)
    local fs = RC:CreateFontString(parent, "OVERLAY", nil, size or 11)
    if text then fs:SetText(text) end
    return fs
end

local function Btn(parent, label, w, h)
    return RC.UI:CreateStyledButton(parent, label, w or 100, h or 22)
end

local function MakeDrop(parent, x, y, w, items, currentVal, onChange)
    local label = RCL["Select..."]
    for _, it in ipairs(items) do
        if it.value == currentVal then label = it.text; break end
    end
    local d = RC.UI:CreateScrollableDropdown(parent, w, label, 12)
    d:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    if d.menu then
        d.menu:SetFrameStrata("TOOLTIP")
        d.menu:SetFrameLevel(200)
    end
    d:SetItems(items, function(val) if onChange then onChange(val) end end)
    d:SetSelectedValue(currentVal, label)
    return d
end

-- preserveScroll: true from in-place edits (dropdowns, up/down, add/delete
-- condition or rule) that rebuild this same page, so the sidebar doesn't
-- jump to the top. Back/list-navigation callers omit it.
function RC:ShowSidebarSmartMacro(frame, preserveScroll)
    -- RC.SmartMacro hooks ChatEdit_InsertLink to fill whichever edit box last
    -- had focus here when an item link is shift-clicked into chat; clear it
    -- on reload so a stale box from a previous view isn't targeted.
    if RC.SmartMacro then RC.SmartMacro._lastFocusedEB = nil end

    local savedScroll = 0
    if preserveScroll and frame.contentFrame then
        savedScroll = frame.contentFrame:GetVerticalScroll() or 0
    end

    self:ClearSidebarContent(self.sidebarConfigFrame)
    local parent = frame.scrollChild

    if not RC.db.smartMacros then
        local lbl = MakeFS(parent, 12,
            RCL["Smart Macro system not yet ready. Try again in a moment."])
        lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, -40)
        do local _c = RC:GetColor("text", "red"); lbl:SetTextColor(_c.r, _c.g, _c.b, 1) end
        return
    end

    -- Every Create/Get/Delete/rule call below lives in Readycheck_Features,
    -- but this panel is drawn by the base addon and its sidebar entry has no
    -- lodAddon, so with Features unticked the page used to render normally
    -- and then error on the first button press. db.smartMacros is seeded by
    -- the base profile builder, so the check above never catches this.
    -- Bailing out here covers all of them at once: nothing further down is
    -- reachable without going through this render.
    if not RC.CreateSmartMacro then
        -- Features runs its smart-macro init on a 1s timer, so opening this
        -- page immediately after login lands here with the addon perfectly
        -- healthy. Only say "enable it" when it genuinely is not loaded.
        local loading = RC.CompanionStatus
            and RC:CompanionStatus("Readycheck_Features") == "loading"
        local lbl = MakeFS(parent, 12, loading
            and RCL["Smart Macros are still starting up. Reopen this page in a moment."]
            or  RCL["Smart Macros need the Readycheck_Features addon. Enable it in your AddOns list and /reload."])
        lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, -40)
        do
            local _c = loading and RC:GetColor("text", "warning") or RC:GetColor("text", "red")
            lbl:SetTextColor(_c.r, _c.g, _c.b, 1)
        end
        return
    end

    if SM_Editor.selectedId then
        local mac = RC:GetSmartMacroById(SM_Editor.selectedId)
        if mac then
            SM_RenderEdit(frame, mac)
        else
            SM_Editor.selectedId = nil
            SM_RenderList(frame)
        end
    else
        SM_RenderList(frame)
    end

    -- deferred a frame so UpdateSidebarScrollbar (run during the render
    -- above) has already resized the scrollbar before clamping to it.
    if savedScroll > 0 then
        C_Timer.After(0, function()
            if not frame.contentFrame then return end
            local cf = frame.contentFrame
            local sb = cf.scrollBar
            local maxScroll = 0
            if sb then
                local _, mv = sb:GetMinMaxValues()
                maxScroll = mv or 0
            end
            local target = math.min(savedScroll, maxScroll)
            cf:SetVerticalScroll(target)
            if sb then sb:SetValue(target) end
        end)
    end
end

function SM_RenderList(frame)
    local parent = frame.scrollChild
    local yPos   = -20
    local TEXT   = RC.UI and RC.UI.TEXT or {}

    local _, newY = RC:CreateSettingsPageHeader(
        parent, yPos,
        RCL["Smart Macros"],
        RCL["Rewrites a macro body automatically based on what you are targeting"],
        "Interface\\Icons\\INV_Scroll_03"
    )
    yPos = newY - 10


    local addBtn = Btn(parent, "+ Add Smart Macro", 165, 26)
    addBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
    addBtn:SetScript("OnClick", function()
        local mac = RC:CreateSmartMacro()
        SM_Editor.selectedId = mac.id
        RC:ShowSidebarSmartMacro(frame)
    end)
    yPos = yPos - 38

    local macros = RC.db.smartMacros
    if #macros == 0 then
        local none = MakeFS(parent, 11,
            RCL["No smart macros configured yet. Click '+ Add Smart Macro' above."])
        none:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
        do local _c = RC:GetColor("text", "disabled"); none:SetTextColor(_c.r, _c.g, _c.b, 1) end
        yPos = yPos - 24
    else
        for _, mac in ipairs(macros) do
            local ruleCount = #mac.rules
            local isUnnamed = (mac.macroName == "")
            local card = RC:CreateSettingsCard(parent, yPos,
                isUnnamed and RCL["(unnamed)"] or mac.macroName)
            local dimC = RC:GetColor("text", "disabled")
            if isUnnamed and card.title then
                card.title:SetTextColor(dimC.r, dimC.g, dimC.b, 1)
            end
            -- Rule count as its own dim label after the title, in place of
            -- an inline colour code inside the title string.
            local countFS = MakeFS(card, 10,
                "- " .. ruleCount .. RCL[" rule"] .. (ruleCount ~= 1 and "s" or ""))
            if card.title then
                countFS:SetPoint("LEFT", card.title, "RIGHT", 6, 0)
            else
                countFS:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -9)
            end
            countFS:SetTextColor(dimC.r, dimC.g, dimC.b, 1)

            local cardY = -34
            local statC = mac.enabled
                and RC:GetColor("text", "success") or RC:GetColor("text", "disabled")
            local statFS = MakeFS(card, 10, mac.enabled and "Enabled" or "Disabled")
            statFS:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
            if statC then statFS:SetTextColor(statC.r, statC.g, statC.b, 1) end
            cardY = cardY - 20

            local shown = 0
            for i, rule in ipairs(mac.rules) do
                if shown >= 3 then
                    local more = MakeFS(card, 10,
                        "... and " .. (#mac.rules - 3) .. RCL[" more"])
                    more:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
                    more:SetTextColor(dimC.r, dimC.g, dimC.b, 1)
                    cardY = cardY - 16
                    break
                end
                local firstCond = (rule.conditions and rule.conditions[1]) or {}
                -- rule.condition (singular) is a fallback for rules saved before
                -- the multi-condition list existed.
                local firstType = firstCond.type or rule.condition or "?"
                local condTxt = CondLabel(firstType)
                if rule.conditions and #rule.conditions > 1 then
                    condTxt = condTxt .. " +" .. (#rule.conditions - 1)
                end
                local valSuffix = (firstType == "named" and firstCond.value and firstCond.value ~= "")
                    and (' "' .. firstCond.value .. '"') or ""
                local itemSuffix = (rule.itemCheck and rule.itemCheck ~= "")
                    and " [if " .. rule.itemCheck .. " avail.]" or ""
                -- BuildBody computes the body from buildAction/buildItem/buildConditional
                -- in Auto Build mode; falls back to the stored manual body if the
                -- SmartMacro module hasn't loaded yet.
                local effectiveBody = (RC.SmartMacro and RC.SmartMacro.BuildBody(rule)) or rule.body or ""
                local bodyShort
                if effectiveBody == "" then
                    bodyShort = "(clears macro)"
                else
                    bodyShort = effectiveBody:sub(1, 30)
                    if #effectiveBody > 30 then bodyShort = bodyShort .. "..." end
                end
                local rowFS = MakeFS(card, 10,
                    i .. ". " .. condTxt .. valSuffix .. itemSuffix
                    .. "  ->  " .. bodyShort)
                rowFS:SetPoint("TOPLEFT",  card, "TOPLEFT",  14, cardY)
                rowFS:SetPoint("TOPRIGHT", card, "TOPRIGHT", -90, cardY)
                rowFS:SetWordWrap(false)
                if TEXT.light then
                    rowFS:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
                end
                cardY = cardY - 16
                shown = shown + 1
            end

            local capId = mac.id
            local editBtn = Btn(card, "Edit", 60, 22)
            editBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -40, -8)
            editBtn:SetScript("OnClick", function()
                SM_Editor.selectedId = capId
                RC:ShowSidebarSmartMacro(frame)
            end)

            local delBtn = RC.UI:CreateXCloseButton(card, 22, function()
                RC.UI:CreateConfirmDialog(
                    RCL["Delete Smart Macro"],
                    RCL["Delete '"] .. (mac.macroName ~= "" and mac.macroName or "unnamed") .. RCL["'?\n\nThis cannot be undone."],
                    function()
                        RC:DeleteSmartMacro(capId)
                        if SM_Editor.selectedId == capId then SM_Editor.selectedId = nil end
                        RC:ShowSidebarSmartMacro(frame)
                    end,
                    nil, RCL["Delete"], true
                )
            end)
            delBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, -8)

            local cardH = math.abs(cardY) + 14
            card:SetHeight(cardH)
            yPos = yPos - cardH - 10
        end
    end

    -- Your macros first; the how-to below them, for when you need it.
    yPos = yPos - 6
    local infoCard = RC:CreateSettingsCard(parent, yPos, RCL["How it works"])
    local cy = -34

    local function CardText(text, size)
        local fs = MakeFS(infoCard, size or 11, text)
        fs:SetPoint("TOPLEFT",  infoCard, "TOPLEFT",  14, cy)
        fs:SetPoint("TOPRIGHT", infoCard, "TOPRIGHT", -14, cy)
        fs:SetJustifyH("LEFT"); fs:SetWordWrap(true)
        if TEXT.light then fs:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3]) end
        cy = cy - math.max(fs:GetStringHeight(), 14) - 6
    end

    CardText("1. Create an empty macro in WoW's Macro UI and give it any name (e.g. SmartBomb).")
    CardText("2. Add a Smart Macro here using that exact name, then add Rules.")
    CardText("3. Rules are checked top-to-bottom on every target change. The first rule whose " ..
        "condition matches AND whose required item (if set) is in your bags and off cooldown is applied.")
    CardText("4. If no rule fires, the macro keeps its last-written body (sticky). A rule " ..
        "with an empty body clears (blanks) the macro when it fires.")
    CardText("5. IN COMBAT THE MACRO CANNOT CHANGE. Blizzard blocks macro edits during " ..
        "combat, so a swap you trigger mid-fight is queued and applied the moment you drop " ..
        "combat. Target your next mob before the pull to get the right body.")
    CardText("6. Use 'Active in' to scope a macro to one raid (and optionally one raid " ..
        "profile). To make the SAME in-game macro do different things per raid config, add " ..
        "several Smart Macros with the same name, each scoped to a different raid/profile.")

    local goldC = RC:GetColor("ui", "accentGold")
    local noteFS = MakeFS(infoCard, 10,
        "Tip: Use 'Required item' to handle shared cooldowns. Example: Name 'Crypt Stalker' + " ..
        "Req. item 'Goblin Sapper Charge' fires only when the sapper is available. " ..
        "When the sapper is on CD the rule is skipped and the next rule (Undead -> Holy Water) fires instead.")
    noteFS:SetPoint("TOPLEFT",  infoCard, "TOPLEFT",  14, cy)
    noteFS:SetPoint("TOPRIGHT", infoCard, "TOPRIGHT", -14, cy)
    noteFS:SetJustifyH("LEFT"); noteFS:SetWordWrap(true)
    if goldC then noteFS:SetTextColor(goldC.r, goldC.g, goldC.b, 0.9) end
    cy = cy - math.max(noteFS:GetStringHeight(), 14) - 8

    infoCard:SetContentHeight(math.abs(cy) + 4)
    yPos = yPos - infoCard:GetHeight() - 14

    yPos = yPos - 20
    RC:UpdateSidebarScrollbar(RC.sidebarConfigFrame, math.abs(yPos) + 40)
end

function SM_RenderEdit(frame, mac)
    local parent = frame.scrollChild
    local yPos   = -20
    local TEXT   = RC.UI and RC.UI.TEXT or {}
    local grayC  = RC:GetColor("text", "disabled")
    local goldC  = RC:GetColor("ui", "accentGold")

    local backBtn = RC.UI:CreateBackButton(parent, "< All Smart Macros", 165, 24)
    backBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
    backBtn:SetScript("OnClick", function()
        SM_Editor.selectedId = nil
        RC:ShowSidebarSmartMacro(frame)
    end)
    yPos = yPos - 34

    local _, newY = RC:CreateSettingsPageHeader(
        parent, yPos,
        RCL["Smart Macro"],
        RCL["Configure conditions and macro body"],
        "Interface\\Icons\\INV_Scroll_03"
    )
    yPos = newY - 10

    local setupCard = RC:CreateSettingsCard(parent, yPos, RCL["Macro setup"])
    local scY = -34

    local nameLbl = MakeFS(setupCard, 11, "Macro Name:")
    nameLbl:SetPoint("TOPLEFT", setupCard, "TOPLEFT", 14, scY)
    nameLbl:SetWidth(LBL_W)
    if TEXT.light then nameLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3]) end

    local nameEB = RC.UI:CreateStyledEditBox(setupCard, { height = 24, width = 200 })
    nameEB:SetPoint("TOPLEFT", setupCard, "TOPLEFT", 14 + LBL_W + 6, scY)
    nameEB.editBox:SetText(mac.macroName or "")
    nameEB.editBox:SetScript("OnEnterPressed", function(self)
        mac.macroName = self:GetText():match("^%s*(.-)%s*$") or ""
        self:ClearFocus()
        RC:SaveConfigurationToProfile()
    end)
    nameEB.editBox:SetScript("OnEditFocusLost", function(self)
        mac.macroName = self:GetText():match("^%s*(.-)%s*$") or ""
        RC:SaveConfigurationToProfile()
    end)
    scY = scY - ROW_H

    local nameHint = MakeFS(setupCard, 10,
        "Must match the in-game macro name exactly.")
    nameHint:SetPoint("TOPLEFT",  setupCard, "TOPLEFT",  14 + LBL_W + 6, scY + 4)
    nameHint:SetPoint("TOPRIGHT", setupCard, "TOPRIGHT", -14, scY + 4)
    nameHint:SetWordWrap(true)
    if grayC then nameHint:SetTextColor(grayC.r, grayC.g, grayC.b, 0.8) end
    scY = scY - 20

    local enableChk = RC.UI:CreateCheckbox(setupCard, RCL["Enabled"], mac.enabled)
    enableChk:SetPoint("TOPLEFT", setupCard, "TOPLEFT", 14, scY)
    enableChk:SetScript("OnClick", function(cb)
        mac.enabled = cb:GetChecked()
        RC:ForceCheckboxUpdate(cb, mac.enabled)
        RC:SaveConfigurationToProfile()
    end)
    scY = scY - ROW_H

    local raidLbl = MakeFS(setupCard, 10, "Active in:")
    raidLbl:SetPoint("TOPLEFT", setupCard, "TOPLEFT", 14, scY)
    raidLbl:SetWidth(70)
    if TEXT.light then raidLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3]) end
    local capMacRaid = mac
    MakeDrop(setupCard, 88, scY, 200, GetRuleRaidScopeItems(), mac.raidFilter or "any",
        function(val)
            capMacRaid.raidFilter = val
            if val == "any" then capMacRaid.profileFilter = "any" end
            RC:SaveConfigurationToProfile()
            -- deferred: rebuilding the page synchronously from inside the
            -- dropdown's own onChange callback would tear down the dropdown
            -- widget while it's still closing itself.
            C_Timer.After(0, function() RC:ShowSidebarSmartMacro(frame, true) end)
        end)
    scY = scY - ROW_H

    local macRaid = mac.raidFilter or "any"
    if macRaid ~= "any" and macRaid ~= "" then
        local profLbl = MakeFS(setupCard, 10, "Profile:")
        profLbl:SetPoint("TOPLEFT", setupCard, "TOPLEFT", 14, scY)
        profLbl:SetWidth(70)
        if TEXT.light then profLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3]) end
        MakeDrop(setupCard, 88, scY, 200, GetRuleProfileItems(macRaid), mac.profileFilter or "any",
            function(val)
                capMacRaid.profileFilter = val
                RC:SaveConfigurationToProfile()
            end)
        scY = scY - ROW_H
    end

    -- Same key, second macro: this macro's key also runs the one picked
    -- here, through a hidden secure button (SmartMacro.lua, SyncChains).
    do
        local alsoLbl = MakeFS(setupCard, 10, "Same key also runs:")
        alsoLbl:SetPoint("TOPLEFT", setupCard, "TOPLEFT", 14, scY)
        alsoLbl:SetWidth(120)
        if TEXT.light then alsoLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3]) end
        local items = { { text = RCL["Nothing"], value = "" } }
        local seen = {}
        local nAcct, nChar = 0, 0
        if GetNumMacros then nAcct, nChar = GetNumMacros() end
        local maxAcct = MAX_ACCOUNT_MACROS or 120
        -- a smart macro that already runs a second macro would be refused
        -- (no loops), so it is not offered - unless it is the current pick
        local runsOwn = {}
        for _, other in ipairs(RC.db.smartMacros or {}) do
            if other ~= mac and other.macroName and other.alsoRun and other.alsoRun ~= "" then
                runsOwn[other.macroName] = true
            end
        end
        local function addIdx(i)
            local nm = GetMacroInfo(i)
            if nm and nm ~= "" and nm ~= mac.macroName and not seen[nm]
               and (not runsOwn[nm] or nm == mac.alsoRun) then
                seen[nm] = true
                items[#items + 1] = { text = nm, value = nm }
            end
        end
        for i = 1, nAcct or 0 do addIdx(i) end
        for i = maxAcct + 1, maxAcct + (nChar or 0) do addIdx(i) end
        table.sort(items, function(a, b)
            if a.value == "" then return true end
            if b.value == "" then return false end
            return a.text:lower() < b.text:lower()
        end)
        MakeDrop(setupCard, 140, scY, 180, items, mac.alsoRun or "",
            function(val)
                mac.alsoRun = (val ~= "" and val) or nil
                RC:SaveConfigurationToProfile()
                local SMx = RC.SmartMacro
                if SMx then
                    if SMx.SyncChains then SMx:SyncChains() end
                    if SMx._lastApplied then SMx._lastApplied[mac.macroName or ""] = nil end
                    if SMx.Evaluate then SMx:Evaluate() end
                end
                C_Timer.After(0, function() RC:ShowSidebarSmartMacro(frame, true) end)
            end)
        scY = scY - ROW_H

        local SMx = RC.SmartMacro
        local why
        if SMx and SMx.ChainTarget then _, why = SMx.ChainTarget(mac) end
        local note
        if not mac.alsoRun or mac.alsoRun == "" then
            note = "Pick a macro here and one press of this macro's key runs both, this one first."
        elseif why == "loop" then
            note = "That macro already runs a second macro of its own, so this one is not added (two macros cannot run each other)."
        elseif SMx and SMx._tooLong and SMx._tooLong[mac.id or mac] then
            note = "Not added: the rule's text plus the /click line would pass the 255-character macro limit. Shorten the rule."
        else
            note = "One press runs this macro and then that one. The second runs through a hidden button nothing can click by accident, so it needs no bar slot - keep only this macro on your bar."
        end
        local alsoHint = MakeFS(setupCard, 10, note)
        alsoHint:SetPoint("TOPLEFT",  setupCard, "TOPLEFT",  140, scY + 4)
        alsoHint:SetWordWrap(true)
        alsoHint:SetJustifyH("LEFT")
        if grayC then alsoHint:SetTextColor(grayC.r, grayC.g, grayC.b, 0.8) end
        -- a fixed width (not a right anchor), so the height is measured
        -- right even before the card's own width is laid out
        local cw = setupCard:GetWidth() or 0
        alsoHint:SetWidth(cw > 300 and (cw - 154) or 300)
        scY = scY - math.max(20, (alsoHint:GetStringHeight() or 14) + 6)
    end

    setupCard:SetContentHeight(math.abs(scY) + 6)
    yPos = yPos - setupCard:GetHeight() - 12

    local rulesCard = RC:CreateSettingsCard(parent, yPos, RCL["Rules"])
    local rcY = -34

    local hintFS = MakeFS(rulesCard, 10,
        "Rules are checked top-to-bottom. The first rule where ANY condition matches fires. " ..
        "If nothing matches, the macro keeps its current body. Swaps triggered while you are " ..
        "in combat are queued and applied when you leave combat - Blizzard blocks macro edits " ..
        "mid-fight.")
    hintFS:SetPoint("TOPLEFT",  rulesCard, "TOPLEFT",  14, rcY)
    hintFS:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -14, rcY)
    hintFS:SetJustifyH("LEFT"); hintFS:SetWordWrap(true)
    if grayC then hintFS:SetTextColor(grayC.r, grayC.g, grayC.b, 0.85) end
    rcY = rcY - math.max(hintFS:GetStringHeight(), 24) - 10

    local rules = mac.rules

    if #rules == 0 then
        local noneFS = MakeFS(rulesCard, 10,
            RCL["No rules yet. Click 'Add Rule' below."])
        noneFS:SetPoint("TOPLEFT", rulesCard, "TOPLEFT", 14, rcY)
        if grayC then noneFS:SetTextColor(grayC.r, grayC.g, grayC.b, 1) end
        rcY = rcY - 20
    else
        for idx, rule in ipairs(rules) do
            if idx > 1 then
                local div = rulesCard:CreateTexture(nil, "ARTWORK")
                div:SetPoint("TOPLEFT",  rulesCard, "TOPLEFT",  14, rcY + 4)
                div:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -14, rcY + 4)
                div:SetHeight(1)
                do local _bn = RC:GetColor("ui", "borderNormal"); div:SetColorTexture(_bn.r, _bn.g, _bn.b, _bn.a or 1) end
                rcY = rcY - 10
            end

            local capRule   = rule
            local capMac    = mac
            local capRuleId = rule.id

            local rNumFS = MakeFS(rulesCard, 10, "Rule " .. idx .. ":")
            rNumFS:SetPoint("TOPLEFT", rulesCard, "TOPLEFT", 14, rcY)
            if goldC then rNumFS:SetTextColor(goldC.r, goldC.g, goldC.b, 1) end

            local delBtn = RC.UI:CreateXCloseButton(rulesCard, 20, function()
                RC:DeleteSmartMacroRule(capMac, capRuleId)
                RC:ShowSidebarSmartMacro(frame, true)
            end)
            delBtn:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -8, rcY)

            local dnBtn = Btn(rulesCard, "Dn", 34, 20)
            dnBtn:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -32, rcY)
            dnBtn:SetScript("OnClick", function()
                RC:MoveSmartMacroRule(capMac, capRuleId, 1)
                RC:ShowSidebarSmartMacro(frame, true)
            end)

            local upBtn = Btn(rulesCard, "Up", 34, 20)
            upBtn:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -70, rcY)
            upBtn:SetScript("OnClick", function()
                RC:MoveSmartMacroRule(capMac, capRuleId, -1)
                RC:ShowSidebarSmartMacro(frame, true)
            end)

            rcY = rcY - 26

            local conditions = capRule.conditions or {}
            for ci, cond in ipairs(conditions) do
                local capCi   = ci
                local capCond = cond
                local condType = cond.type or "always"

                MakeDrop(rulesCard, 14, rcY, COND_W, COND_ITEMS, condType,
                    function(val)
                        capCond.type = val
                        if not CondNeedsValue(val) then capCond.value = "" end
                        RC:SaveConfigurationToProfile()
                        -- same deferral reason as the raid-scope dropdown above.
                        C_Timer.After(0, function()
                            RC:ShowSidebarSmartMacro(frame, true)
                        end)
                    end
                )

                if CondNeedsValue(condType) then
                    local valLbl = MakeFS(rulesCard, 10, "Contains:")
                    valLbl:SetPoint("TOPLEFT", rulesCard, "TOPLEFT", 14 + COND_W + 6, rcY)
                    valLbl:SetWidth(56)
                    if TEXT.light then
                        valLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
                    end
                    local valEB = RC.UI:CreateStyledEditBox(rulesCard, {
                        height = 22, maxLetters = 60,
                    })
                    valEB:SetPoint("TOPLEFT",  rulesCard, "TOPLEFT",  14 + COND_W + 66, rcY)
                    valEB:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -30, rcY)
                    valEB.editBox:SetText(cond.value or "")
                    valEB.editBox:SetScript("OnEnterPressed", function(self)
                        capCond.value = self:GetText()
                        self:ClearFocus()
                        RC:SaveConfigurationToProfile()
                    end)
                    valEB.editBox:SetScript("OnEditFocusLost", function(self)
                        capCond.value = self:GetText()
                        RC:SaveConfigurationToProfile()
                    end)
                end

                if CondNeedsPicker(condType) then
                    local bossItems = GetBossPickerItems()
                    local capCondPicker = capCond
                    local pickerCurrentVal = capCondPicker.value or ""
                    local pickerLabel = pickerCurrentVal ~= "" and pickerCurrentVal or "Pick a boss..."
                    local pickerDrop = RC.UI:CreateScrollableDropdown(
                        rulesCard, COND_W - 2, pickerLabel, 11)
                    pickerDrop:SetPoint("TOPLEFT", rulesCard, "TOPLEFT", 14 + COND_W + 4, rcY)
                    if pickerDrop.menu then
                        pickerDrop.menu:SetFrameStrata("TOOLTIP")
                        pickerDrop.menu:SetFrameLevel(200)
                    end
                    local customLbl = MakeFS(rulesCard, 10, "or type:")
                    customLbl:SetPoint("TOPLEFT", rulesCard, "TOPLEFT", 14 + COND_W + 4, rcY - 30)
                    customLbl:SetWidth(52)
                    if TEXT.light then
                        customLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
                    end
                    local customEB = RC.UI:CreateStyledEditBox(rulesCard, {
                        height = 22, maxLetters = 80,
                    })
                    customEB:SetPoint("TOPLEFT",  rulesCard, "TOPLEFT",  14 + COND_W + 60, rcY - 30)
                    customEB:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -30, rcY - 30)
                    customEB.editBox:SetText(pickerCurrentVal)
                    local function SavePickerValue(name)
                        name = (name or ""):match("^%s*(.-)%s*$")
                        capCondPicker.value = name
                        RC:SaveConfigurationToProfile()
                    end
                    customEB.editBox:SetScript("OnEnterPressed", function(self)
                        SavePickerValue(self:GetText())
                        self:ClearFocus()
                    end)
                    customEB.editBox:SetScript("OnEditFocusLost", function(self)
                        SavePickerValue(self:GetText())
                    end)
                    local filteredItems = {}
                    for _, it in ipairs(bossItems) do
                        if it.value ~= "__header__" then
                            filteredItems[#filteredItems + 1] = it
                        end
                    end
                    pickerDrop:SetItems(filteredItems, function(val)
                        if val and val ~= "" then
                            customEB.editBox:SetText(val)
                            SavePickerValue(val)
                            pickerDrop:SetSelectedValue(val, val)
                        end
                    end)
                    if pickerCurrentVal ~= "" then
                        pickerDrop:SetSelectedValue(pickerCurrentVal, pickerCurrentVal)
                    end
                    rcY = rcY - 30
                end

                if #conditions > 1 then
                    local delCondBtn = RC.UI:CreateXCloseButton(rulesCard, 18, function()
                        table.remove(capRule.conditions, capCi)
                        RC:SaveConfigurationToProfile()
                        RC:ShowSidebarSmartMacro(frame, true)
                    end)
                    delCondBtn:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -8, rcY)
                end

                rcY = rcY - 30
            end

            if #conditions < 5 then
                local addCondBtn = Btn(rulesCard, "+ Condition", 100, 22)
                addCondBtn:SetPoint("TOPLEFT", rulesCard, "TOPLEFT", 14, rcY)
                addCondBtn:SetScript("OnClick", function()
                    if not capRule.conditions then capRule.conditions = {} end
                    table.insert(capRule.conditions, { type = "always" })
                    RC:SaveConfigurationToProfile()
                    RC:ShowSidebarSmartMacro(frame, true)
                end)
                rcY = rcY - 28
            else
                rcY = rcY - 4
            end

            local isAuto = (rule.buildMode ~= "manual")

            local previewFS
            local manBodyEB
            local function RefreshPreview()
                if not previewFS then return end
                local p = (RC.SmartMacro and RC.SmartMacro.BuildBody(capRule)) or ""
                if p ~= "" then
                    previewFS:SetText(p)
                    if goldC then previewFS:SetTextColor(goldC.r, goldC.g, goldC.b, 1) end
                else
                    previewFS:SetText(RCL["(fill in Name above)"])
                    if grayC then previewFS:SetTextColor(grayC.r, grayC.g, grayC.b, 1) end
                end
            end

            local modeChk = RC.UI:CreateCheckbox(rulesCard, RCL["Build macro body automatically"], isAuto)
            modeChk:SetPoint("TOPLEFT", rulesCard, "TOPLEFT", 14, rcY)

            local bodySectionY = rcY - 26

            local autoSec = CreateFrame("Frame", nil, rulesCard)
            autoSec:SetPoint("TOPLEFT",  rulesCard, "TOPLEFT",  14,  bodySectionY)
            autoSec:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -74, bodySectionY)
            autoSec:SetHeight(112)
            if not isAuto then autoSec:Hide() end

            local actLbl = MakeFS(autoSec, 10, "Action:")
            actLbl:SetPoint("TOPLEFT", autoSec, "TOPLEFT", 0, 0)
            actLbl:SetWidth(LBL_W - 4)
            if TEXT.light then
                actLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            end

            MakeDrop(autoSec, LBL_W, 0, 140, ACTION_ITEMS,
                capRule.buildAction or "use",
                function(val)
                    capRule.buildAction = val
                    RC:SaveConfigurationToProfile()
                    RefreshPreview()
                end
            )

            local nameLbl2 = MakeFS(autoSec, 10, "Name:")
            nameLbl2:SetPoint("TOPLEFT", autoSec, "TOPLEFT", LBL_W + 146, 0)
            nameLbl2:SetWidth(42)
            if TEXT.light then
                nameLbl2:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            end

            local itemNameEB = RC.UI:CreateStyledEditBox(autoSec, {
                height = 24, maxLetters = 100
            })
            itemNameEB:SetPoint("TOPLEFT",  autoSec, "TOPLEFT",  LBL_W + 192, 0)
            itemNameEB:SetPoint("TOPRIGHT", autoSec, "TOPRIGHT", 0, 0)
            itemNameEB.editBox:SetText(capRule.buildItem or "")
            -- lets a shift-clicked chat item link auto-fill this box (see
            -- ChatEdit_InsertLink hook in Readycheck_Features/SmartMacro.lua).
            itemNameEB.editBox:SetScript("OnEditFocusGained", function(self)
                if RC.SmartMacro then RC.SmartMacro._lastFocusedEB = self end
            end)
            itemNameEB.editBox:SetScript("OnEnterPressed", function(self)
                capRule.buildItem = self:GetText():match("^%s*(.-)%s*$") or ""
                self:ClearFocus()
                RC:SaveConfigurationToProfile()
                RefreshPreview()
            end)
            itemNameEB.editBox:SetScript("OnEditFocusLost", function(self)
                capRule.buildItem = self:GetText():match("^%s*(.-)%s*$") or ""
                RC:SaveConfigurationToProfile()
                RefreshPreview()
            end)

            local condLbl2 = MakeFS(autoSec, 10, "Conditional:")
            condLbl2:SetPoint("TOPLEFT", autoSec, "TOPLEFT", 0, -30)
            condLbl2:SetWidth(LBL_W - 4)
            if TEXT.light then
                condLbl2:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            end

            local condEB = RC.UI:CreateStyledEditBox(autoSec, { height = 24, maxLetters = 80 })
            condEB:SetPoint("TOPLEFT",  autoSec, "TOPLEFT",  LBL_W, -30)
            condEB:SetPoint("TOPRIGHT", autoSec, "TOPRIGHT", 0, -30)
            condEB.editBox:SetText(capRule.buildConditional or "")
            condEB.editBox:SetScript("OnEnterPressed", function(self)
                capRule.buildConditional = self:GetText():match("^%s*(.-)%s*$") or ""
                self:ClearFocus()
                RC:SaveConfigurationToProfile()
                RefreshPreview()
            end)
            condEB.editBox:SetScript("OnEditFocusLost", function(self)
                capRule.buildConditional = self:GetText():match("^%s*(.-)%s*$") or ""
                RC:SaveConfigurationToProfile()
                RefreshPreview()
            end)

            local condHint2 = MakeFS(autoSec, 10,
                "Optional. Type without brackets: @cursor  |  mod:shift  |  @cursor,mod:shift")
            condHint2:SetPoint("TOPLEFT",  autoSec, "TOPLEFT",  LBL_W, -56)
            condHint2:SetPoint("TOPRIGHT", autoSec, "TOPRIGHT", 0, -56)
            if grayC then condHint2:SetTextColor(grayC.r, grayC.g, grayC.b, 0.75) end

            local prevLbl = MakeFS(autoSec, 10, "Preview:")
            prevLbl:SetPoint("TOPLEFT", autoSec, "TOPLEFT", 0, -72)
            prevLbl:SetWidth(LBL_W - 4)
            if TEXT.light then
                prevLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            end

            previewFS = MakeFS(autoSec, 10, "")
            previewFS:SetPoint("TOPLEFT",  autoSec, "TOPLEFT",  LBL_W, -72)
            previewFS:SetPoint("TOPRIGHT", autoSec, "TOPRIGHT", 0, -72)
            previewFS:SetWordWrap(true)
            RefreshPreview()

            local manSec = CreateFrame("Frame", nil, rulesCard)
            manSec:SetPoint("TOPLEFT",  rulesCard, "TOPLEFT",  14,  bodySectionY)
            manSec:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -74, bodySectionY)
            manSec:SetHeight(68)
            if isAuto then manSec:Hide() end

            local bodyLbl = MakeFS(manSec, 10, "Macro body:")
            bodyLbl:SetPoint("TOPLEFT", manSec, "TOPLEFT", 0, 0)
            bodyLbl:SetWidth(LBL_W - 4)
            if TEXT.light then
                bodyLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            end

            manBodyEB = RC.UI:CreateStyledEditBox(manSec, {
                multiLine    = true,
                scrollable   = true,
                scrollHeight = 52,
                fontSize     = 11,
                maxLetters   = 255,
            })
            manBodyEB:SetPoint("TOPLEFT",  manSec, "TOPLEFT",  LBL_W, 0)
            manBodyEB:SetPoint("TOPRIGHT", manSec, "TOPRIGHT", 0, 0)
            manBodyEB.editBox:SetText(capRule.body or "")
            manBodyEB.editBox:SetScript("OnEditFocusLost", function(self)
                capRule.body = self:GetText()
                RC:SaveConfigurationToProfile()
            end)

            modeChk:SetScript("OnClick", function(cb)
                local nowAuto = cb:GetChecked()
                RC:ForceCheckboxUpdate(cb, nowAuto)
                if nowAuto then
                    capRule.buildMode = "auto"
                    autoSec:Show()
                    manSec:Hide()
                else
                    local gen = (RC.SmartMacro and RC.SmartMacro.BuildBody(capRule)) or ""
                    if gen ~= "" then
                        capRule.body = gen
                        manBodyEB.editBox:SetText(gen)
                    end
                    capRule.buildMode = "manual"
                    autoSec:Hide()
                    manSec:Show()
                end
                RC:SaveConfigurationToProfile()
            end)

            rcY = bodySectionY - 112 - 8

            local effectiveBody = RC.SmartMacro and RC.SmartMacro.BuildBody(capRule) or ""
            if effectiveBody == "" then
                local emptyNoteFS = MakeFS(rulesCard, 10,
                    "Body is empty: when this rule matches it CLEARS the macro (blanks it). " ..
                    "Fill in the Name (auto build) or a Manual body if you want it to write instead.")
                emptyNoteFS:SetPoint("TOPLEFT",  rulesCard, "TOPLEFT",  14, rcY)
                emptyNoteFS:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -14, rcY)
                emptyNoteFS:SetWordWrap(true)
                if goldC then emptyNoteFS:SetTextColor(goldC.r, goldC.g, goldC.b, 1) end
                rcY = rcY - math.max(emptyNoteFS:GetStringHeight(), 28) - 6
            end

            local itemLbl = MakeFS(rulesCard, 10, "Req. item:")
            itemLbl:SetPoint("TOPLEFT", rulesCard, "TOPLEFT", 14, rcY)
            itemLbl:SetWidth(LBL_W - 4)
            if TEXT.light then
                itemLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            end

            local itemEB = RC.UI:CreateStyledEditBox(rulesCard, {
                height = 24, maxLetters = 80
            })
            itemEB:SetPoint("TOPLEFT",  rulesCard, "TOPLEFT",  14 + LBL_W, rcY)
            itemEB:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -74, rcY)
            itemEB.editBox:SetText(rule.itemCheck or "")
            -- same item-link auto-fill hook as the Auto Build Name box above.
            itemEB.editBox:SetScript("OnEditFocusGained", function(self)
                if RC.SmartMacro then RC.SmartMacro._lastFocusedEB = self end
            end)
            itemEB.editBox:SetScript("OnEnterPressed", function(self)
                capRule.itemCheck = self:GetText():match("^%s*(.-)%s*$") or ""
                self:ClearFocus()
                RC:SaveConfigurationToProfile()
            end)
            itemEB.editBox:SetScript("OnEditFocusLost", function(self)
                capRule.itemCheck = self:GetText():match("^%s*(.-)%s*$") or ""
                RC:SaveConfigurationToProfile()
            end)
            rcY = rcY - 32

            local itemHint = MakeFS(rulesCard, 10,
                "Optional: rule skipped if this item is not in bags or is on cooldown. " ..
                "Use exact item name, e.g. 'Goblin Sapper Charge'.")
            itemHint:SetPoint("TOPLEFT",  rulesCard, "TOPLEFT",  14 + LBL_W, rcY + 4)
            itemHint:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -74, rcY + 4)
            itemHint:SetWordWrap(true)
            if grayC then itemHint:SetTextColor(grayC.r, grayC.g, grayC.b, 0.75) end
            rcY = rcY - math.max(itemHint:GetStringHeight(), 28) - 10

        end
    end

    rcY = rcY - 8

    local addRuleBtn = Btn(rulesCard, "+ Add Rule", 110, 24)
    addRuleBtn:SetPoint("TOPLEFT", rulesCard, "TOPLEFT", 14, rcY)
    addRuleBtn:SetScript("OnClick", function()
        RC:AddSmartMacroRule(mac)
        RC:ShowSidebarSmartMacro(frame, true)
    end)
    rcY = rcY - 34

    rulesCard:SetContentHeight(math.abs(rcY) + 8)
    yPos = yPos - rulesCard:GetHeight() - 12

    local tipsCard = RC:CreateSettingsCard(parent, yPos, RCL["Tips & examples"])
    local tcY = -34

    local tips = {
        "Each condition row is OR: if any match, the rule fires. Add multiple to group targets: [Undead, No target] -> holy water for undead mobs and when resting.",
        "Example setup: Rule 1 [Undead, No target] -> Holy Water. Rule 2 [Not Undead] -> Dynamite. Beasts hit rule 2, undead and login hit rule 1.",
        "'Always (fires regardless)' overrides everything below it. Only use it alone on a true catch-all last rule.",
        "Dense Dynamite and Holy Water share the same 1-min cooldown. The 'Req. item' check handles fallthrough automatically.",
        "Goblin Sapper Charge has a 5-min cooldown. Use it as the Req. item on a named rule and add a creature-type fallback rule below it.",
        "Leave Req. item blank on fallback rules so they always fire when the condition matches.",
    }
    for _, tip in ipairs(tips) do
        local tipFS = MakeFS(tipsCard, 10, "- " .. tip)
        tipFS:SetPoint("TOPLEFT",  tipsCard, "TOPLEFT",  14, tcY)
        tipFS:SetPoint("TOPRIGHT", tipsCard, "TOPRIGHT", -14, tcY)
        tipFS:SetJustifyH("LEFT"); tipFS:SetWordWrap(true)
        if TEXT.light then tipFS:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3]) end
        tcY = tcY - math.max(tipFS:GetStringHeight(), 14) - 6
    end

    tipsCard:SetContentHeight(math.abs(tcY) + 6)
    yPos = yPos - tipsCard:GetHeight() - 12

    yPos = yPos - 4
    local delMacBtn = Btn(parent, "Delete This Smart Macro", 195, 26)
    delMacBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
    if delMacBtn.text then local _rc = RC:GetColor("text", "red"); delMacBtn.text:SetTextColor(_rc.r, _rc.g, _rc.b, 1) end
    local delMacId = mac.id
    delMacBtn:SetScript("OnClick", function()
        RC.UI:CreateConfirmDialog(
            RCL["Delete Smart Macro"],
            RCL["Delete '"] .. (mac.macroName ~= "" and mac.macroName or "unnamed") .. RCL["'?\n\nThis cannot be undone."],
            function()
                RC:DeleteSmartMacro(delMacId)
                SM_Editor.selectedId = nil
                RC:ShowSidebarSmartMacro(frame)
            end,
            nil, RCL["Delete"], true
        )
    end)
    yPos = yPos - 38

    RC:UpdateSidebarScrollbar(RC.sidebarConfigFrame, math.abs(yPos) + 40)
end

if RC and RC.DebugPrint then RC:DebugPrint("SidebarSmartMacro loaded", "system") end
