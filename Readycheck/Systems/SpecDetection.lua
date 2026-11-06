------------------------------------------------------------------------
-- Readycheck - Spec Detection
-- Reads the talent tree into a spec key, and shows the spec/talent
-- banner on raid entry. Warrior has hand-written rules (it is the only
-- class where the off-tab talents matter); every other class is simply
-- whichever tab holds the most points.
-- The scan is cached and only re-runs when a talent event dirties it.
------------------------------------------------------------------------
local function InitializeSpecDetection()
    local RC = _G.Readycheck
    if not RC then
        C_Timer.After(0.1, InitializeSpecDetection)
        return
    end

    if not RC.db or not RC.UI then
        C_Timer.After(0.2, InitializeSpecDetection)
        return
    end

    -- Indexed by talent tab, so the non-warrior path can map "most
    -- points" straight to a spec. Warrior entries are unused by that
    -- path - its keys come from the specs table below instead.
    local CLASS_SPECS = {
        WARRIOR = {
            [1] = { key = "arms", name = "Arms",        icon = "Interface\\Icons\\Ability_Rogue_Eviscerate" },
            [2] = { key = "fury", name = "Fury",        icon = "Interface\\Icons\\Ability_Warrior_InnerRage" },
            [3] = { key = "prot", name = "Protection",  icon = "Interface\\Icons\\Ability_Warrior_DefensiveStance" },
        },
        PALADIN = {
            [1] = { key = "pal_holy",  name = "Holy",          icon = "Interface\\Icons\\Spell_Holy_HolyBolt" },
            [2] = { key = "pal_prot",  name = "Protection",    icon = "Interface\\Icons\\Spell_Holy_DevotionAura" },
            [3] = { key = "pal_ret",   name = "Retribution",   icon = "Interface\\Icons\\Spell_Holy_AuraOfLight" },
        },
        HUNTER = {
            [1] = { key = "hun_bm",    name = "Beast Mastery", icon = "Interface\\Icons\\Ability_Hunter_BeastTaming" },
            [2] = { key = "hun_mm",    name = "Marksmanship",  icon = "Interface\\Icons\\Ability_Marksmanship" },
            [3] = { key = "hun_surv",  name = "Survival",      icon = "Interface\\Icons\\Ability_Hunter_SwiftStrike" },
        },
        ROGUE = {
            [1] = { key = "rog_assn",  name = "Assassination", icon = "Interface\\Icons\\Ability_Rogue_Eviscerate" },
            [2] = { key = "rog_combat",name = "Combat",        icon = "Interface\\Icons\\Ability_BackStab" },
            [3] = { key = "rog_sub",   name = "Subtlety",      icon = "Interface\\Icons\\Ability_Stealth" },
        },
        PRIEST = {
            [1] = { key = "pri_disc",  name = "Discipline",    icon = "Interface\\Icons\\Spell_Holy_WordFortitude" },
            [2] = { key = "pri_holy",  name = "Holy",          icon = "Interface\\Icons\\Spell_Holy_GuardianSpirit" },
            [3] = { key = "pri_shadow",name = "Shadow",        icon = "Interface\\Icons\\Spell_Shadow_ShadowWordPain" },
        },
        SHAMAN = {
            [1] = { key = "sha_ele",   name = "Elemental",     icon = "Interface\\Icons\\Spell_Nature_Lightning" },
            [2] = { key = "sha_enh",   name = "Enhancement",   icon = "Interface\\Icons\\Spell_Nature_LightningShield" },
            [3] = { key = "sha_resto", name = "Restoration",   icon = "Interface\\Icons\\Spell_Nature_MagicImmunity" },
        },
        MAGE = {
            [1] = { key = "mag_arcane",name = "Arcane",        icon = "Interface\\Icons\\Spell_Holy_MagicalSentry" },
            [2] = { key = "mag_fire",  name = "Fire",          icon = "Interface\\Icons\\Spell_Fire_FireBolt02" },
            [3] = { key = "mag_frost", name = "Frost",         icon = "Interface\\Icons\\Spell_Frost_FrostBolt02" },
        },
        WARLOCK = {
            [1] = { key = "lok_affl",  name = "Affliction",    icon = "Interface\\Icons\\Spell_Shadow_DeathCoil" },
            [2] = { key = "lok_demo",  name = "Demonology",    icon = "Interface\\Icons\\Spell_Shadow_Metamorphosis" },
            [3] = { key = "lok_destro",name = "Destruction",   icon = "Interface\\Icons\\Spell_Shadow_RainOfFire" },
        },
        DRUID = {
            [1] = { key = "dru_bal",   name = "Balance",       icon = "Interface\\Icons\\Spell_Nature_StarFall" },
            [2] = { key = "dru_feral", name = "Feral Combat",  icon = "Interface\\Icons\\Ability_Racial_BearForm" },
            [3] = { key = "dru_resto", name = "Restoration",   icon = "Interface\\Icons\\Spell_Nature_HealingTouch" },
        },
    }

    RC.specDetection = {
        currentSpec = nil,
        lastZone = nil,
        detectedTalents = {},
        talentsDirty = true,
        classSpecs = CLASS_SPECS,

        -- furyProt has no talent tab of its own; it is a warrior build
        -- detected by rule below. Non-warrior keys are appended at load.
        specs = {
            fury = {
                name = "Fury",
                icon = "Interface\\Icons\\Ability_Warrior_InnerRage",
                colorKey = {"status", "error"}
            },
            furyProt = {
                name = "Fury/Prot",
                icon = "Interface\\Icons\\Ability_Warrior_DefensiveStance",
                colorKey = {"spec", "furyProt"}
            },
            arms = {
                name = "Arms",
                icon = "Interface\\Icons\\Ability_Rogue_SliceDice",
                colorKey = {"ui", "headerText"}
            },
            prot = {
                name = "Protection",
                icon = "Interface\\Icons\\Ability_Warrior_ShieldWall",
                colorKey = {"spec", "prot"}
            }
        },

        -- Warrior-only whitelist: names must match the talent tooltip
        -- exactly or the talent is silently dropped from the display.
        -- Other classes bypass this and record every ranked talent.
        keyTalents = {
            ["Improved Heroic Strike"] = { tab = 1, abbrev = "Imp HS", important = true },
            ["Deflection"] = { tab = 1, abbrev = "Deflection", important = false },
            ["Improved Rend"] = { tab = 1, abbrev = "Imp Rend", important = false },
            ["Improved Charge"] = { tab = 1, abbrev = "Imp Charge", important = true },
            ["Tactical Mastery"] = { tab = 1, abbrev = "Tac Mastery", important = true },
            ["Improved Overpower"] = { tab = 1, abbrev = "Imp Overpower", important = true },
            ["Anger Management"] = { tab = 1, abbrev = "Anger Mgmt", important = true },
            ["Deep Wounds"] = { tab = 1, abbrev = "Deep Wounds", important = true },
            ["Two-Handed Weapon Specialization"] = { tab = 1, abbrev = "2H Spec", important = true },
            ["Impale"] = { tab = 1, abbrev = "Impale", important = true },
            ["Axe Specialization"] = { tab = 1, abbrev = "Axe Spec", important = true },
            ["Sweeping Strikes"] = { tab = 1, abbrev = "Sweeping", important = true },
            ["Mace Specialization"] = { tab = 1, abbrev = "Mace Spec", important = true },
            ["Sword Specialization"] = { tab = 1, abbrev = "Sword Spec", important = true },
            ["Polearm Specialization"] = { tab = 1, abbrev = "Polearm Spec", important = false },
            ["Improved Hamstring"] = { tab = 1, abbrev = "Imp Hamstring", important = false },
            ["Mortal Strike"] = { tab = 1, abbrev = "Mortal Strike", important = true },

            ["Booming Voice"] = { tab = 2, abbrev = "Boom Voice", important = false },
            ["Cruelty"] = { tab = 2, abbrev = "Cruelty", important = true },
            ["Improved Demoralizing Shout"] = { tab = 2, abbrev = "Imp Demo", spellId = 12879, important = true },
            ["Unbridled Wrath"] = { tab = 2, abbrev = "Unbridled", important = true },
            ["Improved Cleave"] = { tab = 2, abbrev = "Imp Cleave", important = true },
            ["Piercing Howl"] = { tab = 2, abbrev = "Piercing", important = false },
            ["Blood Craze"] = { tab = 2, abbrev = "Blood Craze", important = false },
            ["Improved Battle Shout"] = { tab = 2, abbrev = "Imp BShout", important = true },
            ["Dual Wield Specialization"] = { tab = 2, abbrev = "DW Spec", important = true },
            ["Improved Execute"] = { tab = 2, abbrev = "Imp Execute", important = true },
            ["Enrage"] = { tab = 2, abbrev = "Enrage", important = true },
            ["Improved Slam"] = { tab = 2, abbrev = "Imp Slam", important = false },
            ["Death Wish"] = { tab = 2, abbrev = "Death Wish", important = true },
            ["Improved Intercept"] = { tab = 2, abbrev = "Imp Intercept", important = true },
            ["Improved Berserker Rage"] = { tab = 2, abbrev = "Imp Zerk Rage", important = false },
            ["Flurry"] = { tab = 2, abbrev = "Flurry", important = true },
            ["Bloodthirst"] = { tab = 2, abbrev = "Bloodthirst", important = true },

            ["Shield Specialization"] = { tab = 3, abbrev = "Shield Spec", important = true },
            ["Improved Bloodrage"] = { tab = 3, abbrev = "Imp Bloodrage", important = true },
            ["Toughness"] = { tab = 3, abbrev = "Toughness", important = true },
            ["Iron Will"] = { tab = 3, abbrev = "Iron Will", important = false },
            ["Last Stand"] = { tab = 3, abbrev = "Last Stand", important = true },
            ["Improved Shield Block"] = { tab = 3, abbrev = "Imp SBlock", important = true },
            ["Improved Revenge"] = { tab = 3, abbrev = "Imp Revenge", important = true },
            ["Defiance"] = { tab = 3, abbrev = "Defiance", important = true },
            ["Improved Sunder Armor"] = { tab = 3, abbrev = "Imp Sunder", important = true },
            ["Improved Disarm"] = { tab = 3, abbrev = "Imp Disarm", important = false },
            ["Improved Taunt"] = { tab = 3, abbrev = "Imp Taunt", important = true },
            ["Concussion Blow"] = { tab = 3, abbrev = "Concussion", important = true },
            ["Improved Shield Bash"] = { tab = 3, abbrev = "Imp SBash", important = false },
            ["One-Handed Weapon Specialization"] = { tab = 3, abbrev = "1H Spec", important = true },
            ["Shield Slam"] = { tab = 3, abbrev = "Shield Slam", important = true },
        }
    }

    local _, playerClass = UnitClass("player")
    if playerClass and CLASS_SPECS[playerClass] then
        for _, tabData in pairs(CLASS_SPECS[playerClass]) do
            if not RC.specDetection.specs[tabData.key] then
                RC.specDetection.specs[tabData.key] = {
                    name = tabData.name,
                    icon = tabData.icon,
                    colorKey = nil,
                }
            end
        end
    end

    -- Named for warriors but handles every class. Walks the whole talent
    -- tree, so it must stay behind the talentsDirty cache.
    function RC:DetectWarriorSpec()
        if RC.Profiler then RC.Profiler:StartTiming("SpecDetection") end

        local _, class = UnitClass("player")
        if not class then
            if RC.Profiler then RC.Profiler:StopTiming("SpecDetection") end
            return nil
        end

        if not self.specDetection.talentsDirty and self.specDetection.currentSpec then
            if RC.Profiler then RC.Profiler:StopTiming("SpecDetection") end
            return self.specDetection.currentSpec
        end

        self.specDetection.detectedTalents = {}

        local tabPoints = {0, 0, 0}
        -- a client without the old talent API (WoW Forever) reads as no
        -- talents rather than erroring
        local GetNumTalentTabs = (GetNumTalentTabs and GetNumTalents and GetTalentInfo) and GetNumTalentTabs
            or function() return 0 end

        local hasDefiance = false
        local hasLastStand = false
        local defianceRank = 0

        for tab = 1, GetNumTalentTabs() do
            for talent = 1, GetNumTalents(tab) do
                local name, icon, tier, column, rank, maxRank, isExceptional, available = GetTalentInfo(tab, talent)

                if name and rank and rank > 0 then
                    tabPoints[tab] = (tabPoints[tab] or 0) + rank

                    if class == "WARRIOR" then
                        if name == "Defiance" then
                            hasDefiance = true
                            defianceRank = rank
                        elseif name == "Last Stand" then
                            hasLastStand = true
                        end

                        local keyTalent = self.specDetection.keyTalents and self.specDetection.keyTalents[name]
                        if keyTalent then
                            self.specDetection.detectedTalents[name] = {
                                rank = rank,
                                maxRank = maxRank,
                                icon = icon,
                                tab = tab,
                                abbrev = keyTalent.abbrev,
                                important = keyTalent.important
                            }
                        end
                    else
                        self.specDetection.detectedTalents[name] = {
                            rank = rank,
                            maxRank = maxRank,
                            icon = icon,
                            tab = tab,
                            abbrev = name,
                            important = true,
                        }
                    end
                end
            end
        end

        local spec = nil

        if class == "WARRIOR" then
            local armsTalents = tabPoints[1] or 0
            local furyTalents = tabPoints[2] or 0
            local protTalents = tabPoints[3] or 0

            -- Defiance and Last Stand are the tanking tells, so they
            -- weight the prot count beyond their raw point cost.
            if hasDefiance then
                protTalents = protTalents + (defianceRank or 0)
            end
            if hasLastStand then
                protTalents = protTalents + 1
            end

            -- Order matters: furyProt has to be caught before the plain
            -- prot test, or a deep-fury tank reads as prot.
            if hasDefiance and furyTalents >= 20 then
                spec = "furyProt"
            elseif hasLastStand or protTalents >= 30 then
                spec = "prot"
            elseif armsTalents > furyTalents and armsTalents >= 20 then
                spec = "arms"
            else
                spec = "fury"
            end

            self:DebugPrint("=== SPEC DETECTION ===", "core")
            self:DebugPrint("Spec: " .. (spec or "unknown"), "core")
            self:DebugPrint("Defiance: " .. (hasDefiance and "YES" or "NO"), "core")
            self:DebugPrint("Last Stand: " .. (hasLastStand and "YES" or "NO"), "core")
            self:DebugPrint("Arms talents: " .. armsTalents, "core")
            self:DebugPrint("Fury talents: " .. furyTalents, "core")
            self:DebugPrint("Prot talents: " .. protTalents, "core")
        else
            local classData = CLASS_SPECS[class]
            if classData then
                local bestTab, bestPts = 1, -1
                for t = 1, 3 do
                    if (tabPoints[t] or 0) > bestPts then
                        bestPts = tabPoints[t] or 0
                        bestTab = t
                    end
                end
                local tabData = classData[bestTab]
                if tabData then
                    spec = tabData.key
                end
                self:DebugPrint("=== SPEC DETECTION ("..class..") ===", "core")
                self:DebugPrint("Tab points: " .. (tabPoints[1] or 0) .. "/" .. (tabPoints[2] or 0) .. "/" .. (tabPoints[3] or 0), "core")
                self:DebugPrint("Spec: " .. (spec or "unknown"), "core")
            end
        end

        self.specDetection.currentSpec = spec
        self.specDetection.talentsDirty = false

        if RC.Profiler then RC.Profiler:StopTiming("SpecDetection") end
        return spec
    end

    function RC:GetSpecColor(specKey)
        local specData = self.specDetection.specs[specKey]
        if not specData then
            return RC:GetColor("text", "normal")
        end
        local key = specData.colorKey
        if key then
            local c = RC:GetColor(key[1], key[2])
            if c then return c end
        end
        local fallbacks = {
            fury     = {r=1,   g=0.3, b=0.3, a=1},
            furyProt = {r=0.8, g=0.5, b=1.0, a=1},
            arms     = {r=1,   g=0.82,b=0,   a=1},
            prot     = {r=0.3, g=0.7, b=1.0, a=1},
        }
        return fallbacks[specKey] or {r=0.9, g=0.9, b=0.9, a=1}
    end

    -- One canonical priority list per warrior spec, shared by
    -- GetTalentSummary (text, short cap) and GetDisplayTalents (icons).
    -- GetTalentSummary previously carried its own drifted lists; those were
    -- strict subsets of these, so the union kept here is exactly these.
    local SPEC_TALENT_PRIORITY = {
        fury = {
            "Bloodthirst", "Flurry", "Death Wish", "Improved Execute",
            "Improved Battle Shout", "Improved Cleave", "Dual Wield Specialization",
            "Cruelty", "Enrage", "Improved Intercept", "Unbridled Wrath", "Improved Demoralizing Shout",
            "Improved Berserker Rage", "Piercing Howl", "Improved Slam",
            "Sweeping Strikes", "Deep Wounds", "Impale", "Tactical Mastery",
            "Improved Heroic Strike", "Deflection", "Anger Management", "Improved Overpower",
            "Defiance", "Improved Shield Block", "Last Stand", "Toughness",
            "Improved Bloodrage", "Shield Specialization"
        },
        furyProt = {
            "Bloodthirst", "Flurry", "Death Wish", "Defiance", "Improved Shield Block",
            "Cruelty", "Last Stand", "Shield Slam", "Improved Taunt", "Improved Demoralizing Shout",
            "One-Handed Weapon Specialization", "Toughness", "Concussion Blow",
            "Improved Heroic Strike", "Improved Cleave", "Unbridled Wrath", "Enrage",
            "Improved Bloodrage", "Shield Specialization", "Improved Sunder Armor",
            "Improved Revenge", "Iron Will",
            "Tactical Mastery", "Anger Management", "Deep Wounds", "Impale", "Improved Overpower"
        },
        arms = {
            "Mortal Strike", "Sweeping Strikes", "Deep Wounds", "Impale",
            "Sword Specialization", "Axe Specialization", "Mace Specialization",
            "Two-Handed Weapon Specialization", "Tactical Mastery", "Improved Overpower",
            "Anger Management", "Improved Heroic Strike", "Deflection", "Improved Charge",
            "Improved Hamstring", "Polearm Specialization",
            "Cruelty", "Improved Demoralizing Shout", "Unbridled Wrath", "Improved Battle Shout", "Enrage",
            "Flurry", "Death Wish", "Improved Execute",
            "Defiance", "Improved Shield Block", "Last Stand", "Toughness",
            "Improved Bloodrage"
        },
        prot = {
            "Shield Slam", "Last Stand", "Defiance", "Improved Shield Block",
            "Concussion Blow", "One-Handed Weapon Specialization", "Improved Taunt", "Improved Demoralizing Shout",
            "Improved Revenge", "Improved Sunder Armor", "Toughness",
            "Shield Specialization", "Improved Bloodrage", "Iron Will",
            "Improved Shield Bash", "Improved Disarm",
            "Tactical Mastery", "Anger Management", "Deflection", "Improved Heroic Strike",
            "Deep Wounds", "Impale", "Improved Overpower",
            "Cruelty", "Unbridled Wrath", "Improved Cleave", "Piercing Howl"
        },
    }

    -- A user-saved order wins, with any defaults it omits appended, so
    -- reordering never silently drops a talent from the list.
    local function ResolvePriorityTalents(spec, sd)
        local defaultTalents = SPEC_TALENT_PRIORITY[spec] or {}
        local talentOrder = sd.talentOrder or {}
        local savedOrder = talentOrder[spec]
        if not savedOrder then
            return defaultTalents
        end
        local priorityTalents, seen = {}, {}
        for _, t in ipairs(savedOrder) do
            priorityTalents[#priorityTalents + 1] = t
            seen[t] = true
        end
        for _, t in ipairs(defaultTalents) do
            if not seen[t] then
                priorityTalents[#priorityTalents + 1] = t
            end
        end
        return priorityTalents
    end

    -- Text list for tooltips/chat. GetDisplayTalents below is the icon
    -- equivalent: same shape, and it honours hiddenTalents.
    function RC:GetTalentSummary(spec, maxTalents)
        maxTalents = maxTalents or 6
        local talents = {}
        local detected = self.specDetection.detectedTalents
        local sd = self.db.specDetection or {}

        for _, talentName in ipairs(ResolvePriorityTalents(spec, sd)) do
            if detected[talentName] then
                local data = detected[talentName]
                local displayText
                if data.maxRank == 1 then
                    displayText = data.abbrev
                else
                    displayText = string.format("%s %d/%d", data.abbrev, data.rank, data.maxRank)
                end
                table.insert(talents, displayText)

                if #talents >= maxTalents then
                    break
                end
            end
        end

        return talents
    end

    function RC:HasTalent(talentName)
        local detected = self.specDetection.detectedTalents
        return detected[talentName] ~= nil
    end

    -- THE POPUP'S DRAWING, shared by the live popup and the settings
    -- preview: NewSpecDisplayFrame builds the pieces on any parent,
    -- StyleSpecDisplay applies the look settings (specDetection.look;
    -- every nil field is the popup's original look), FillSpecDisplay puts
    -- a spec and its talents in and sizes the frame.
    RC.SPEC_POPUP_SHOW = { style = "fade", duration = 0.5, easing = "linear" }
    RC.SPEC_POPUP_HIDE = { style = "fade", duration = 0.5, easing = "linear" }
    RC.SPEC_POPUP_FONTS = {
        title = { size = 18, outline = "OUTLINE" },
        sub   = { size = 11, outline = "OUTLINE" },
        rank  = { size = 9, outline = "OUTLINE" },
    }

    function RC:SpecPopupLook()
        local sd = self.db and self.db.specDetection
        local l = sd and sd.look
        return type(l) == "table" and l or {}
    end

    function RC:NewSpecDisplayFrame(parent, name)
        local frame = CreateFrame("Frame", name, parent)
        frame:SetSize(320, 100)

        -- Flat fill + the framework's 1px black ring (D4 on-screen frame).
        local bg = frame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture((self.UI and self.UI.FLAT) or "Interface\\Buttons\\WHITE8X8")
        frame.bg = bg
        if self.UI and self.UI.CreateSimpleBorder then
            frame.border = self.UI:CreateSimpleBorder(frame, 1)
        end

        frame.icon = frame:CreateTexture(nil, "ARTWORK")
        frame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        frame.specText = self:CreateFontString(frame, "OVERLAY", nil, 18, "OUTLINE")
        frame.specText:SetText("")
        frame.subText = self:CreateFontString(frame, "OVERLAY", nil, 11, "OUTLINE")
        frame.subText:SetText(RCL["Entering Raid"])

        frame.talentContainer = CreateFrame("Frame", nil, frame)
        frame.talentContainer:SetHeight(50)
        frame.talentIcons = {}
        return frame
    end

    function RC:StyleSpecDisplay(frame)
        local look = self:SpecPopupLook()
        local F = RC.SPEC_POPUP_FONTS
        local w = look.width or 320
        local iconSize = look.iconSize or 48
        frame:SetWidth(w)
        frame:SetScale(look.scale or 1)

        local bgCol = look.bgColor or RC:GetColor("ui", "cardBackground")
        if look.bgTexture == nil then
            frame.bg:SetTexture((self.UI and self.UI.FLAT) or "Interface\\Buttons\\WHITE8X8")
        else
            -- nil = flat, "" = the global texture, else an LSM name
            self:ApplyTextureSpec(frame.bg, (look.bgTexture ~= "" and look.bgTexture) or nil)
        end
        frame.bg:SetVertexColor(bgCol.r, bgCol.g, bgCol.b, look.bgColor and (bgCol.a or 1) or 0.95)
        if frame.border and self.UI.UpdateBorderColor then
            self.UI:UpdateBorderColor(frame.border, look.borderColor or RC:GetColor("ui", "borderNormal"))
        end

        frame.icon:SetSize(iconSize, iconSize)
        frame.icon:ClearAllPoints()
        frame.icon:SetPoint("TOPLEFT", frame, "TOPLEFT", 15, -15)
        self:ApplyFontSpec(frame.specText, look.titleFont, F.title)
        self:ApplyFontSpec(frame.subText, look.subFont, F.sub)
        frame.specText:ClearAllPoints()
        frame.specText:SetPoint("LEFT", frame.icon, "RIGHT", 12, 8)
        frame.subText:ClearAllPoints()
        frame.subText:SetPoint("LEFT", frame.icon, "RIGHT", 12, -10)
        -- specDetection.anchors.title / .sub: a spec moves the text from there
        local anc = RC.db and RC.db.specDetection and RC.db.specDetection.anchors
        if type(anc) == "table" then
            local function To(k)
                if k == "icon" then return frame.icon elseif k == "title" then return frame.specText
                elseif k == "sub" then return frame.subText elseif k == "frame" then return frame end
            end
            frame._sdTitleDef = frame._sdTitleDef or {}
            frame._sdSubDef = frame._sdSubDef or {}
            RC.UI:AnchorOver(frame.specText, anc.title, frame._sdTitleDef, "LEFT", frame.icon, "RIGHT", 12, 8, To)
            RC.UI:AnchorOver(frame.subText, anc.sub, frame._sdSubDef, "LEFT", frame.icon, "RIGHT", 12, -10, To)
        end
        local subCol = look.subColor or RC:GetColor("text", "gray")
        frame.subText:SetTextColor(subCol.r, subCol.g, subCol.b, 1)

        frame.talentContainer:ClearAllPoints()
        frame.talentContainer:SetPoint("TOPLEFT", frame, "TOPLEFT", 15, -(iconSize + 27))
        frame.talentContainer:SetPoint("RIGHT", frame, "RIGHT", -15, 0)
        for _, ic in pairs(frame.talentIcons) do
            self:ApplyFontSpec(ic.rankText, look.rankFont, F.rank)
        end
        -- layer / clamp, fade rules, shadow / glow (the standard; its own
        -- scale and colours stay its own)
        if self.ApplyFrameCustom then
            self:ApplyFrameCustom(frame, function() return RC.db and RC.db.specDetection end,
                { scale = false, sample = (frame ~= self.specDisplayFrame) })
        end
    end

    -- talents: { { icon, rank, maxRank }, ... } or nil for none.
    function RC:FillSpecDisplay(frame, specData, specKey, talents)
        local look = self:SpecPopupLook()
        local iconSize = look.iconSize or 48
        frame.icon:SetTexture(specData.icon)
        frame.specText:SetText(specData.name)
        local sc = RC:GetSpecColor(specKey)
        frame.specText:SetTextColor(sc.r, sc.g, sc.b, 1)

        for _, iconFrame in pairs(frame.talentIcons) do
            iconFrame:Hide()
        end

        -- Height is driven by how many icon rows we end up drawing.
        local base = iconSize + 32
        local frameHeight = base
        if talents and #talents > 0 then
            local size = look.talentSize or 28
            local spacing = 4
            local iconsPerRow = look.perRow or 8
            for i, talent in ipairs(talents) do
                local iconFrame = self:GetTalentIcon(frame, i)
                local row = math.floor((i - 1) / iconsPerRow)
                local col = (i - 1) % iconsPerRow
                iconFrame:SetSize(size, size)
                iconFrame:ClearAllPoints()
                iconFrame:SetPoint("TOPLEFT", frame.talentContainer, "TOPLEFT",
                    col * (size + spacing), -row * (size + spacing))
                iconFrame.icon:SetTexture(talent.icon)
                if (talent.maxRank or 1) > 1 then
                    iconFrame.rankText:SetText(talent.rank .. "/" .. talent.maxRank)
                    iconFrame.rankText:Show()
                else
                    iconFrame.rankText:Hide()
                end
                iconFrame:Show()
            end
            local rows = math.ceil(#talents / iconsPerRow)
            frameHeight = base + rows * (size + spacing) + 10
            frame.talentContainer:Show()
        else
            frame.talentContainer:Hide()
        end
        frame:SetHeight(frameHeight)
    end

    -- Built once and cached across shows (frames are never GC'd by the
    -- client); ShowSpecDisplay re-skins icon/text/height on every show.
    function RC:CreateSpecDisplayFrame()
        if self.specDisplayFrame then
            return self.specDisplayFrame
        end

        local frame = self:NewSpecDisplayFrame(UIParent, "ReadycheckSpecDisplay")
        frame:SetPoint("TOP", UIParent, "TOP", 0, -150)
        frame:SetFrameStrata("TOOLTIP")
        frame:SetFrameLevel(1000)
        frame:Hide()

        self.specDisplayFrame = frame
        return frame
    end

    -- Lazy pool that only grows; callers hide the leftovers themselves.
    function RC:GetTalentIcon(frame, index)
        if not frame.talentIcons[index] then
            local iconFrame = CreateFrame("Frame", nil, frame.talentContainer)
            iconFrame:SetSize(28, 28)

            local icon = iconFrame:CreateTexture(nil, "ARTWORK")
            icon:SetAllPoints()
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            iconFrame.icon = icon

            local border = iconFrame:CreateTexture(nil, "OVERLAY")
            border:SetPoint("TOPLEFT", -1, 1)
            border:SetPoint("BOTTOMRIGHT", 1, -1)
            border:SetColorTexture(0, 0, 0, 1)
            iconFrame.border = border
            icon:SetDrawLayer("OVERLAY", 1)

            local rankText = iconFrame:CreateFontString(nil, "OVERLAY")
            rankText:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", -1, 1)
            self:ApplyFontSpec(rankText, self:SpecPopupLook().rankFont, RC.SPEC_POPUP_FONTS.rank)
            local rankCol = self:GetColor("text", "white")
            rankText:SetTextColor(rankCol.r, rankCol.g, rankCol.b)
            iconFrame.rankText = rankText

            frame.talentIcons[index] = iconFrame
        end
        return frame.talentIcons[index]
    end

    -- Icon list for the banner. Warrior only - every other class returns
    -- empty, so the banner shows the spec name with no talent row.
    function RC:GetDisplayTalents(spec, maxTalents)
        maxTalents = maxTalents or 8
        local talents = {}
        local detected = self.specDetection.detectedTalents
        local sd = self.db.specDetection or {}
        local hiddenTalents = sd.hiddenTalents or {}

        local _, class = UnitClass("player")
        if class ~= "WARRIOR" then
            return talents
        end

        for _, talentName in ipairs(ResolvePriorityTalents(spec, sd)) do
            if detected[talentName] and not hiddenTalents[talentName] then
                local data = detected[talentName]
                table.insert(talents, {
                    name = talentName,
                    rank = data.rank,
                    maxRank = data.maxRank,
                    icon = data.icon,
                    abbrev = data.abbrev
                })

                if #talents >= maxTalents then
                    break
                end
            end
        end

        return talents
    end

    function RC:ShowSpecDisplay(spec)
        local sd = self.db.specDetection or {}
        if sd.enabled == false then
            self:DebugPrint("ShowSpecDisplay: Disabled in settings", "core")
            return
        end

        if not spec then
            spec = self:DetectWarriorSpec()
        end

        if not spec then
            self:DebugPrint("ShowSpecDisplay: No spec detected", "core")
            return
        end

        local specData = self.specDetection.specs[spec]
        if not specData then
            self:DebugPrint("ShowSpecDisplay: No spec data for " .. tostring(spec), "core")
            return
        end

        -- Both land on raid entry and would overlap on screen.
        if self.consumablesChecker and self.consumablesChecker.frame and self.consumablesChecker.frame:IsShown() then
            self.consumablesChecker.frame:Hide()
        end

        local frame = self:CreateSpecDisplayFrame()

        frame:SetFrameStrata("TOOLTIP")
        frame:SetFrameLevel(1000)
        frame:Raise()

        local look = self:SpecPopupLook()
        local M = RC.Motion
        -- back at rest before it is re-laid out
        M.Stop(frame)
        if frame._rcHoldTimer then frame._rcHoldTimer:Cancel() frame._rcHoldTimer = nil end
        frame:ClearAllPoints()
        frame:SetPoint("TOP", UIParent, "TOP", look.x or 0, look.y or -150)

        local showTalents = sd.showTalents ~= false
        local maxTalents = sd.maxTalentsShown or 8
        local talents
        if showTalents and maxTalents > 0 then
            talents = self:GetDisplayTalents(spec, maxTalents)
        end
        self:StyleSpecDisplay(frame)
        self:FillSpecDisplay(frame, specData, spec, talents)

        -- In, a hold of displayDuration, out: the page's animation
        -- settings, defaulting to the old 0.5s linear fades.
        local displayDuration = sd.displayDuration or 4
        frame:SetAlpha(1)
        frame:Hide()
        M.Show(frame, M.Normalize(look.showAnim, RC.SPEC_POPUP_SHOW), function()
            frame._rcHoldTimer = C_Timer.NewTimer(displayDuration, function()
                frame._rcHoldTimer = nil
                if frame:IsShown() then
                    M.Hide(frame, M.Normalize(self:SpecPopupLook().hideAnim, RC.SPEC_POPUP_HIDE))
                end
            end)
        end)

        -- off unless switched on in the Spec Detection settings
        if sd.playSound then
            if look.soundKey and look.soundKey ~= "" then
                self:PlaySoundKey(look.soundKey)
            else
                PlaySound(8959)
            end
        end

        self:DebugPrint("Spec display shown: " .. specData.name, "core")
    end

    -- RC:IsInRaidInstance lives in Core_Boot.lua with the other shared
    -- zone predicates.

    function RC:OnZoneChanged()
        local currentZone = GetRealZoneText()

        self:DebugPrint("Zone changed: " .. tostring(currentZone), "core")
        self:DebugPrint("In raid instance: " .. tostring(self:IsInRaidInstance()), "core")

        if self.SaveConfigurationToProfile then
            self:SaveConfigurationToProfile()
        end

        -- PLAYER_ENTERING_WORLD also routes here, so the lastZone guard
        -- is what stops the banner replaying on every loading screen.
        if self:IsInRaidInstance() then
            if self.specDetection.lastZone ~= currentZone then
                self:DebugPrint("New raid zone detected", "core")

                local sd = self.db.specDetection or {}
                local showOnRaidEntry = sd.showOnRaidEntry ~= false
                local enabled = sd.enabled ~= false

                if enabled and showOnRaidEntry then
                    self:DebugPrint("Showing spec display", "core")

                    if self.consumablesChecker and self.consumablesChecker.frame and self.consumablesChecker.frame:IsShown() then
                        self.consumablesChecker.frame:Hide()
                    end

                    local spec = self:DetectWarriorSpec()
                    self:ShowSpecDisplay(spec)

                    local specData = self.specDetection.specs[spec]
                    if specData then
                        local sc = RC:GetSpecColor(spec)
                        self:Print(RCL["Current Spec: |cff"] ..
                            string.format("%02x%02x%02x", sc.r * 255, sc.g * 255, sc.b * 255) ..
                            specData.name .. "|r")
                    end
                else
                    self:DetectWarriorSpec()
                end
            end
        end

        self.specDetection.lastZone = currentZone
    end

    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    -- (not every client still has this event; a missing one must not stop the rest)
    pcall(eventFrame.RegisterEvent, eventFrame, "CHARACTER_POINTS_CHANGED")
    eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
    eventFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")

    eventFrame:SetScript("OnEvent", function(self, event, ...)
        if event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
            RC:OnZoneChanged()
        elseif event == "CHARACTER_POINTS_CHANGED" or event == "PLAYER_TALENT_UPDATE" or event == "ACTIVE_TALENT_GROUP_CHANGED" then
            RC.specDetection.talentsDirty = true
            RC:DebugPrint("Talent change detected (" .. event .. "), marking spec cache dirty", "core")
            -- GetTalentInfo still reports the pre-change tree for a
            -- moment after these events, hence the delay before re-read.
            C_Timer.After(0.5, function()
                local oldSpec = RC.specDetection.currentSpec
                local newSpec = RC:DetectWarriorSpec()

                if oldSpec ~= newSpec then
                    RC:DebugPrint("Spec changed from " .. tostring(oldSpec) .. " to " .. tostring(newSpec), "core")
                    local specData = RC.specDetection.specs[newSpec]
                    if specData then
                        local sc = RC:GetSpecColor(newSpec)
                        RC:Print(RCL["Spec changed to: |cff"] ..
                            string.format("%02x%02x%02x", sc.r * 255, sc.g * 255, sc.b * 255) ..
                            specData.name .. "|r")
                    end
                end
            end)
        end
    end)

    RC:DebugPrint("Spec Detection System loaded with UIFramework integration", "core")

    -- Talents are not readable at load; prime the cache once settled.
    C_Timer.After(2.0, function()
        local spec = RC:DetectWarriorSpec()
        RC:DebugPrint("Initial spec detection complete: " .. tostring(spec), "core")
    end)
end

InitializeSpecDetection()
