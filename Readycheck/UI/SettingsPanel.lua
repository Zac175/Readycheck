------------------------------------------------------------------------
-- Readycheck - Settings Panel Data & Helpers
-- Owns the boss icon lookup (RC.bossIcons), checkbox force-refresh
-- helpers used by the scrollable settings pages, and a standalone
-- crosshair drag-test frame for previewing reminder position (separate
-- code path from UI/UIMover.lua). RC:OpenConfig() is the entry point
-- into the advanced config window.
------------------------------------------------------------------------
-- Taint-safe API locals (fallbacks on RC.Compat, built in Core;
-- never write _G - a written Blizzard global taints its readers)
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetSpellInfo = GetSpellInfo or (RCC and RCC.Compat and RCC.Compat.GetSpellInfo)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local table_insert, table_remove, table_sort = table.insert, table.remove, table.sort
local string_format, string_lower = string.format, string.lower
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetTime = GetTime

local function InitializeConfigUI()
    local RC = _G.Readycheck
    if not RC then
        C_Timer.After(0.1, InitializeConfigUI)
        return
    end

    local C = {
        black        = {0,    0,    0,    1   },
        buttonBg     = {0.18, 0.18, 0.18, 0.9 },
        cardBg       = {0.10, 0.10, 0.10, 1   },
        cardBgDim    = {0.07, 0.07, 0.07, 1   },
        elementBg    = {0.12, 0.12, 0.12, 0.5 },
        windowBg     = {0.08, 0.08, 0.08, 0.95},
        windowBgLight= {0.12, 0.12, 0.12, 0.95},
        gold         = {1,    0.82, 0,    1   },
        goldDim      = {0.8,  0.65, 0,    1   },
        brightGreen  = {0.5,  1,    0.5,  1   },
        softGreen    = {0.3,  0.8,  0.3,  1   },
        selectedGreen= {0.2,  0.6,  0.2,  1   },
    }

    local T = {
        white = {1, 1, 1, 1},
        bright = {0.9, 0.9, 0.9, 1},
        normal = {0.7, 0.7, 0.7, 1},
        dim = {0.8, 0.8, 0.8, 1},
        medGray = {0.6, 0.6, 0.6, 1},
        yellow = {1, 1, 0, 1},
        yellowLight = {1, 1, 0.8, 1},
        gold = {1, 0.82, 0, 1},
        orange = {1, 0.6, 0.3, 1},
        orangeDark = {1, 0.4, 0, 1},
        red = {1, 0.2, 0.2, 1},
        redLight = {1, 0.8, 0.8, 1},
        green = {0.8, 1, 0.8, 1},
        greenSoft = {0.7, 0.9, 0.7, 1},
        blue = {0.8, 0.8, 1, 1},
    }

    RC.bossIcons = {
        ["Lucifron"] = "Interface\\Icons\\Spell_Shadow_ShadowWordDominate",
        ["Magmadar"] = "Interface\\Icons\\Spell_Fire_SelfDestruct",
        ["Gehennas"] = "Interface\\Icons\\Spell_Fire_Immolation",
        ["Garr"] = "Interface\\Icons\\Spell_Fire_SelfDestruct",
        ["Baron Geddon"] = "Interface\\Icons\\Spell_Fire_SelfDestruct",
        ["Shazzrah"] = "Interface\\Icons\\Spell_Nature_WispSplode",
        ["Sulfuron Harbinger"] = "Interface\\Icons\\Spell_Fire_Fireball",
        ["Golemagg the Incinerator"] = "Interface\\Icons\\Spell_Fire_Volcano",
        ["Majordomo Executus"] = "Interface\\Icons\\Spell_Fire_FireArmor",
        ["Ragnaros"] = "Interface\\Icons\\achievement_boss_ragnaros",

        ["Razorgore the Untamed"] = "Interface\\Icons\\Spell_Shadow_UnholyFrenzy",
        ["Vaelastrasz the Corrupt"] = "Interface\\Icons\\Spell_Shadow_DeathScream",
        ["Broodlord Lashlayer"] = "Interface\\Icons\\Ability_Warrior_Challange",
        ["Firemaw"] = "Interface\\Icons\\Spell_Fire_SelfDestruct",
        ["Ebonroc"] = "Interface\\Icons\\Spell_Shadow_Charm",
        ["Flamegor"] = "Interface\\Icons\\Spell_Shadow_UnholyFrenzy",
        ["Chromaggus"] = "Interface\\Icons\\Spell_Nature_Acid_01",
        ["Nefarian"] = "Interface\\Icons\\achievement_boss_nefarion",

        ["The Prophet Skeram"] = "Interface\\Icons\\Spell_Nature_AstralRecal",
        ["Silithid Royalty"] = "Interface\\Icons\\Ability_Warrior_Challange",
        ["Battleguard Sartura"] = "Interface\\Icons\\Ability_Whirlwind",
        ["Fankriss the Unyielding"] = "Interface\\Icons\\Spell_Nature_InsectSwarm",
        ["Viscidus"] = "Interface\\Icons\\Spell_Frost_FrostShock",
        ["Princess Huhuran"] = "Interface\\Icons\\Spell_Nature_InsectSwarm",
        ["Twin Emperors"] = "Interface\\Icons\\Spell_Shadow_Shadetruesight",
        ["Ouro"] = "Interface\\Icons\\Spell_Nature_Earthquake",
        ["C'Thun"] = "Interface\\Icons\\achievement_boss_cthun",

        ["Anub'Rekhan"] = "Interface\\Icons\\achievement_boss_anubarak",
        ["Grand Widow Faerlina"] = "Interface\\Icons\\achievement_boss_grandwidowfaerlina",
        ["Maexxna"] = "Interface\\Icons\\achievement_boss_maexxna",
        ["Noth the Plaguebringer"] = "Interface\\Icons\\Spell_Shadow_CurseOfAchimonde",
        ["Heigan the Unclean"] = "Interface\\Icons\\achievement_boss_heigantheunclean",
        ["Loatheb"] = "Interface\\Icons\\achievement_boss_loatheb",
        ["Instructor Razuvious"] = "Interface\\Icons\\Spell_DeathKnight_Butcher2",
        ["Gothik the Harvester"] = "Interface\\Icons\\Spell_Shadow_ShadowWordPain",
        ["Four Horsemen"] = "Interface\\Icons\\achievement_boss_fourhorsemen",
        ["Patchwerk"] = "Interface\\Icons\\achievement_boss_patchwerk",
        ["Grobbulus"] = "Interface\\Icons\\Spell_Shadow_CallofBone",
        ["Gluth"] = "Interface\\Icons\\Spell_Shadow_AnimateDead",
        ["Thaddius"] = "Interface\\Icons\\achievement_boss_thaddius",
        ["Sapphiron"] = "Interface\\Icons\\achievement_boss_sapphiron_01",
        ["Kel'Thuzad"] = "Interface\\Icons\\achievement_boss_kelthuzad_01"
    }

function RC:RegisterCheckboxWithData(checkbox, getValueFunc, setValueFunc)
    if not checkbox then return end

    checkbox.wrGetValue = getValueFunc
    checkbox.wrSetValue = setValueFunc

    local currentValue = getValueFunc()
    self:ForceCheckboxUpdate(checkbox, currentValue)
end

function RC:ForceCheckboxUpdate(checkbox, state)
    if not checkbox then return end

    checkbox:SetChecked(state)

    local checkTexture = checkbox.check or checkbox:GetCheckedTexture()
    if checkTexture then
        if state then
            checkTexture:Show()
            checkTexture:SetAlpha(1)
        else
            checkTexture:Hide()
            checkTexture:SetAlpha(0)
        end
    end

    local normalTexture = checkbox:GetNormalTexture()
    if normalTexture then
        normalTexture:SetAlpha(1)
    end

    if state then
        checkbox:SetChecked(true)
    else
        checkbox:SetChecked(false)
    end
end

-- Walks two levels only (direct children of scrollChild, plus their
-- children); a checkbox nested any deeper is not force-refreshed.
function RC:RefreshAllCheckboxes(frame)
    if not frame or not frame.scrollChild then return end

    local children = {frame.scrollChild:GetChildren()}

    for _, child in ipairs(children) do
        if child:GetObjectType() == "CheckButton" then
            if child.wrGetValue then
                local actualValue = child.wrGetValue()
                self:ForceCheckboxUpdate(child, actualValue)
            else
                local isChecked = child:GetChecked()
                self:ForceCheckboxUpdate(child, isChecked)
            end
        end

        local grandchildren = {child:GetChildren()}
        for _, grandchild in ipairs(grandchildren) do
            if grandchild:GetObjectType() == "CheckButton" then
                if grandchild.wrGetValue then
                    local actualValue = grandchild.wrGetValue()
                    self:ForceCheckboxUpdate(grandchild, actualValue)
                else
                    local isChecked = grandchild:GetChecked()
                    self:ForceCheckboxUpdate(grandchild, isChecked)
                end
            end
        end
    end
end

    -- Stand-in for the reminder frame, draggable while the real one is hidden.
    function RC:ShowDragTestFrame()
        if self.dragTestFrame then
            self.dragTestFrame:Hide()
            self.dragTestFrame:SetParent(nil)
            self.dragTestFrame = nil
        end

        local iconSize = self.db.iconSize or 80
        local frame = CreateFrame("Frame", "ReadycheckDragTest", UIParent)
        frame:SetSize(iconSize, iconSize)

        frame:SetFrameStrata("DIALOG")
        frame:SetToplevel(true)
        frame:SetFrameLevel(100)

        RC.Position.Apply(frame, self.db.xOffset or 0, self.db.yOffset or 200, "CENTER")

        frame:EnableMouse(true)
        frame:SetClampedToScreen(true)
        frame:SetMovable(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", function(dragFrame)
            if self.db.dragEnabled then dragFrame:StartMoving() end
        end)
        frame:SetScript("OnDragStop", function(dragFrame)
            if not self.db.dragEnabled then return end
            dragFrame:StopMovingOrSizing()
            local x, y = RC.Position.Capture(dragFrame, "CENTER")
            if x then
                self:SaveReminderFramePosition(x, y)
                self:SyncReminderPositionUI()
            end
        end)

        frame.bg = frame:CreateTexture(nil, "BACKGROUND")
        frame.bg:SetAllPoints()
        frame.bg:SetColorTexture(C.windowBgLight[1], C.windowBgLight[2], C.windowBgLight[3], C.windowBgLight[4])

        frame.border = frame:CreateTexture(nil, "BORDER")
        frame.border:SetPoint("CENTER")
        frame.border:SetSize(iconSize + 4, iconSize + 4)
        frame.border:SetColorTexture(C.goldDim[1], C.goldDim[2], C.goldDim[3], C.goldDim[4])

        frame.icon = frame:CreateTexture(nil, "ARTWORK")
        frame.icon:SetAllPoints()
        frame.icon:SetTexture("Interface\\Icons\\Spell_Shadow_DeathPact")
        frame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        frame.hLine = frame:CreateTexture(nil, "OVERLAY", nil, 7)
        frame.hLine:SetSize(iconSize + 20, 3)
        frame.hLine:SetPoint("CENTER")
        frame.hLine:SetColorTexture(C.brightGreen[1], C.brightGreen[2], C.brightGreen[3], C.brightGreen[4])

        frame.vLine = frame:CreateTexture(nil, "OVERLAY", nil, 7)
        frame.vLine:SetSize(3, iconSize + 20)
        frame.vLine:SetPoint("CENTER")
        frame.vLine:SetColorTexture(C.brightGreen[1], C.brightGreen[2], C.brightGreen[3], C.brightGreen[4])

        frame.label = self:CreateFontString(frame, "OVERLAY", nil, 11)
        frame.label:SetPoint("TOP", frame, "BOTTOM", 0, -5)
        frame.label:SetText("CENTER: X=" .. math.floor(xOff) .. " Y=" .. math.floor(yOff))
        frame.label:SetTextColor(T.yellow[1], T.yellow[2], T.yellow[3], T.yellow[4])

        frame.label2 = self:CreateFontString(frame, "OVERLAY", nil, 9)
        frame.label2:SetPoint("TOP", frame.label, "BOTTOM", 0, -2)
        frame.label2:SetText(RCL["This crosshair = center of all reminders"])
        frame.label2:SetTextColor(T.normal[1], T.normal[2], T.normal[3], T.normal[4])

        self.dragTestFrame = frame
        frame:Show()
        frame:Raise()

        self:DebugPrint("Drag frame at X=" .. xOff .. " Y=" .. yOff, "config")
    end

    function RC:HideDragTestFrame()
        if self.dragTestFrame then
            self.dragTestFrame:Hide()
                self:DebugPrint("Drag test frame hidden", "config")
        end
    end

    function RC:OpenConfig(navigationTarget)
        self.pendingNavigation = navigationTarget
        self:CreateAdvancedConfigWindow()

    end

    RC:DebugPrint("Configuration UI complete - All systems operational", "config")

end

InitializeConfigUI()
