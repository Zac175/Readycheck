local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local GetItemCount = GetItemCount or (RCC and RCC.Compat and RCC.Compat.GetItemCount)
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local table_insert, table_sort = table.insert, table.sort
local string_format = string.format
local CreateFrame = CreateFrame
local RC = _G.Readycheck
if not (RC and RC.UI) then return end
RC._sbc = RC._sbc or {}
local _sbc = RC._sbc
local TEXT = _sbc.TEXT
------------------------------------------------------------------------
-- Readycheck - Boss & Trash Notes Settings
-- Behavior/Boss Notes/Trash Notes/Look/Text/Animation/Sound/Position
-- tabs edit db.bossNotes; the pane previews the note box (StyleBossNotesBox). Boss/trash note
-- text keys are scoped per raid profile via ProfileKeyForBoss /
-- ProfileKeyForRaidShort ("name|raid|profile"); ResolveScopedNoteKey
-- migrates old case/whitespace-mismatched keys onto the canonical one.
-- Kill-triggered trash notes share one scoped combat-log reader -
-- RebuildTrashKillWatch must run after any trigger/mob edit.
------------------------------------------------------------------------
    local BOSS_NOTES_RAIDS = {
        {key="naxx", label=RCL["Naxxramas"], bosses={
            "Anub'Rekhan","Grand Widow Faerlina","Maexxna",
            "Noth the Plaguebringer","Heigan the Unclean","Loatheb",
            "Instructor Razuvious","Gothik the Harvester","The Four Horsemen",
            "Patchwerk","Grobbulus","Gluth","Thaddius",
            "Sapphiron","Kel'Thuzad",
        }},
        {key="aq40", label="AQ40", bosses={
            "The Prophet Skeram","Silithid Royalty","Battleguard Sartura",
            "Fankriss the Unyielding","Viscidus","Princess Huhuran",
            "Twin Emperors","Ouro","C'Thun",
        }},
        {key="bwl", label="BWL", bosses={
            "Razorgore the Untamed","Vaelastrasz the Corrupt","Broodlord Lashlayer",
            "Firemaw","Ebonroc","Flamegor","Chromaggus","Nefarian",
        }},
        {key="mc", label="MC", bosses={
            "Lucifron","Magmadar","Gehennas","Garr","Baron Geddon",
            "Shazzrah","Sulfuron Harbinger","Golemagg the Incinerator",
            "Majordomo Executus","Ragnaros",
        }},
        {key="zg", label="ZG", bosses={
            "High Priest Venoxis","High Priestess Jeklik","High Priest Mar'li",
            "Bloodlord Mandokir","Edge of Madness","High Priest Thekal",
            "High Priestess Arlokk","Jin'do the Hexxer","Hakkar",
        }},
        {key="onyxia", label=RCL["Onyxia"], bosses={"Onyxia"}},
    }

    local TRASH_NOTES_RAIDS = {
        {key="naxx", label=RCL["Naxxramas"], mobs={
            "Naxxramas Acolyte","Naxxramas Cultist","Venom Stalker","Tomb Horror","Naxxramas Skeleton","Plagued Gargoyle",
            "Naxxramas Warrior","Infectious Ghoul","Plague Slime","Stoneskin Gargoyle",
            "Deathknight Cavalier","Patchwork Golem","Soldier of the Frozen Wastes",
            "Crypt Reaver","Undead Horror","Guardian of Icecrown",
        }},
        {key="aq40", label="AQ40", mobs={
            "Anubisath Sentinel","Anubisath Defender","Anubisath Guardian","Anubisath Warrior",
            "Giant Anubisath Sentinel",
            "Qiraji Warrior","Qiraji Swarmguard","Qiraji Mindslayer","Qiraji Battle Tank","Qiraji Slayer",
            "Ruins Warder","Ruins Sentinel",
        }},
        {key="bwl", label="BWL", mobs={
            "Chromatic Whelp","Chromatic Dragonspawn",
            "Blackwing Spellbinder","Blackwing Technician","Blackwing Legionnaire","Blackwing Mage",
            "Death Talon Wyrmguard","Death Talon Flamescale","Death Talon Seether","Death Talon Hatcher",
            "Scarshield Spellbinder","Scarshield Legionnaire","Scarshield Sentry",
            "Master Elemental Shaper Krixix","Grethok the Controller",
        }},
        {key="mc", label="MC", mobs={
            "Core Hound","Ancient Core Hound","Molten Giant","Firelord",
            "Flamewaker","Flamewaker Elite","Flamewaker Priest",
            "Lava Reaver","Lava Surger","Lava Annihilator",
        }},
        {key="zg", label="ZG", mobs={
            "Gurubashi Warrior","Gurubashi Berserker","Gurubashi Blood Drinker","Gurubashi Headhunter",
            "Zulian Prowler","Zulian Tiger","Zulian Crocolisk","Zulian Hydra",
            "Vile Bat","Bloodseeker Bat",
            "Vilebranch Axe Thrower",
        }},
        {key="onyxia", label=RCL["Onyxia"], mobs={
            "Onyxian Whelp","Onyxian Warder","Onyxian Lair Guard",
        }},
    }

    local _lastFocusedEB = nil

    local NOTE_COLORS = {
        {hex="|cFFFFFFFF", r=1,    g=1,    b=1,    label=RCL["White"]     },
        {hex="|cFFFFD700", r=1,    g=0.84, b=0,    label=RCL["Gold"]      },
        {hex="|cFFFF4444", r=1,    g=0.27, b=0.27, label=RCL["Red"]       },
        {hex="|cFFFF8C00", r=1,    g=0.55, b=0,    label=RCL["Orange"]    },
        {hex="|cFF44FF44", r=0.27, g=1,    b=0.27, label=RCL["Green"]     },
        {hex="|cFF44DDFF", r=0.27, g=0.87, b=1,    label=RCL["Cyan"]      },
        {hex="|cFFAA88FF", r=0.67, g=0.53, b=1,    label=RCL["Purple"]    },
        {hex="|cFFFF69B4", r=1,    g=0.41, b=0.71, label=RCL["Pink"]      },
        {hex="|cFFAAAAAA", r=0.67, g=0.67, b=0.67, label=RCL["Lt Grey"]   },
    }

    local RAID_MARKERS = {
        {name="Star",     tex="|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:13:13|t"},
        {name="Circle",   tex="|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_2:13:13|t"},
        {name="Diamond",  tex="|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_3:13:13|t"},
        {name="Triangle", tex="|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_4:13:13|t"},
        {name="Moon",     tex="|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_5:13:13|t"},
        {name="Square",   tex="|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_6:13:13|t"},
        {name="Cross",    tex="|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_7:13:13|t"},
        {name="Skull",    tex="|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:13:13|t"},
    }

    local TEXT_INSERTS = {
        {label="-",   tip="Bullet dash",          text="- "          },
        {label="--",  tip="Divider line",         text="-- "         },
        {label="->",  tip="Right arrow",          text="-> "         },
        {label=">>",  tip="Double arrow / indent",text=">> "         },
        {label="<-",  tip="Left arrow",           text="<- "         },
        {label="[!]", tip="Warning / alert",      text="[!] "        },
        {label="[i]", tip="Info note",            text="[i] "        },
        {label="===", tip="Section divider",      text="=========== "},
    }

    local function CreateNoteEditBox(parent, db, key, containerW, containerH, fallbackKey)
        containerH = containerH or 70
        local SB_W = 10
        local PAD  = 3

        local bgC    = RC:GetColor("ui", "elementBackground")
        local trackC = RC:GetColor("scrollbar", "track")
        local thumbC = RC:GetColor("scrollbar", "thumb")

        local con = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        con:SetHeight(containerH)
        con:SetBackdrop({ bgFile="Interface\\Buttons\\WHITE8X8",
                          edgeFile="Interface\\Buttons\\WHITE8X8", edgeSize=1 })
        con:SetBackdropColor(bgC.r, bgC.g, bgC.b, 0.9)
        do local _bn=RC:GetColor("ui","borderNormal"); con:SetBackdropBorderColor(_bn.r,_bn.g,_bn.b,_bn.a or 1) end

        local sbTrack = con:CreateTexture(nil, "BACKGROUND")
        sbTrack:SetPoint("TOPRIGHT",    con, "TOPRIGHT",    -1, -1)
        sbTrack:SetPoint("BOTTOMRIGHT", con, "BOTTOMRIGHT", -1,  1)
        sbTrack:SetWidth(SB_W)
        sbTrack:SetTexture(RC.UI.FLAT)
        sbTrack:SetVertexColor(trackC.r, trackC.g, trackC.b, trackC.a or 0.8)

        local sbThumb = con:CreateTexture(nil, "OVERLAY")
        sbThumb:SetWidth(SB_W - 2)
        sbThumb:SetTexture("Interface\\Buttons\\WHITE8X8")
        sbThumb:SetVertexColor(thumbC.r, thumbC.g, thumbC.b, 1)
        sbThumb:Hide()

        local sf = CreateFrame("ScrollFrame", nil, con)
        sf:SetPoint("TOPLEFT",     con, "TOPLEFT",      PAD,             -PAD)
        sf:SetPoint("BOTTOMRIGHT", con, "BOTTOMRIGHT", -(SB_W + PAD + 1), PAD)

        local initW = math.max(20, (containerW or 100) - PAD - SB_W - PAD - 1)
        local _nc = RC:GetColor("text", "normal")
        local eb = RC.UI:CreateEditBox(sf, {
            width = initW, height = containerH, multiLine = true,
            maxLetters = 1000, fontSize = 10,
            textColor = { _nc.r, _nc.g, _nc.b, _nc.a },
        })

        local speakBtn = RC.UI:CreateStyledButton(con, RCL["Speak"], 44, 15)
        speakBtn:SetPoint("BOTTOMRIGHT", con, "BOTTOMRIGHT", -(SB_W + 3), 3)
        speakBtn:SetFrameLevel((sf:GetFrameLevel() or 1) + 2)
        speakBtn:SetScript("OnClick", function()
            local txt = eb:GetText()
            if txt and txt ~= "" and RC.SpeakTTSPreview then
                local plain = txt:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                RC:SpeakTTSPreview(plain, true)
            end
        end)
        local initialText = db.notes[key]
        if (not initialText or initialText == "") and fallbackKey then
            initialText = db.notes[fallbackKey]
        end
        eb:SetText(initialText or "")
        sf:SetScrollChild(eb)

        con:HookScript("OnSizeChanged", function(self, w)
            if w and w > 0 then
                eb:SetWidth(math.max(20, w - PAD - SB_W - PAD - 1))
            end
        end)

        local function UpdateThumb()
            local maxScroll = sf:GetVerticalScrollRange()
            if maxScroll <= 0 then
                sbThumb:Hide()
                return
            end
            local trackH   = containerH - 2
            local ratio    = containerH / (containerH + maxScroll)
            local thumbH   = math.max(8, math.floor(trackH * ratio))
            local scroll   = sf:GetVerticalScroll()
            local frac     = scroll / maxScroll
            local thumbY   = -math.floor(frac * (trackH - thumbH))
            sbThumb:SetHeight(thumbH)
            sbThumb:ClearAllPoints()
            sbThumb:SetPoint("TOPRIGHT", con, "TOPRIGHT", -2, -1 + thumbY)
            sbThumb:Show()
        end

        eb:HookScript("OnTextChanged", function(self)
            local lines = self:GetNumLines() or 1
            local needed = math.max(sf:GetHeight(), lines * 14 + 6)
            if self:GetHeight() < needed then
                self:SetHeight(needed)
            end
        end)

        sf:SetScript("OnScrollRangeChanged", function()
            UpdateThumb()
        end)

        sf:EnableMouseWheel(true)
        sf:SetScript("OnMouseWheel", function(self, delta)
            local maxScroll = self:GetVerticalScrollRange()
            local newScroll = math.min(maxScroll, math.max(0, self:GetVerticalScroll() - delta * 18))
            self:SetVerticalScroll(newScroll)
            UpdateThumb()
        end)

        eb:SetScript("OnCursorChanged", function(self, x, y, w, h)
            local absY  = math.abs(y)
            local scroll = sf:GetVerticalScroll()
            local visH  = sf:GetHeight()
            if absY < scroll then
                sf:SetVerticalScroll(math.max(0, absY - 2))
            elseif absY + h > scroll + visH then
                sf:SetVerticalScroll(absY + h - visH + 2)
            end
            UpdateThumb()
        end)

        local function Save()
            local t = eb:GetText()
            db.notes[key] = (t and t ~= "") and t or nil
            RC:SaveConfigurationToProfile()
        end

        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

        eb:HookScript("OnEditFocusGained", function(self)
            _lastFocusedEB = self
            local gold = RC:GetColor("ui", "accentGold")
            con:SetBackdropBorderColor(gold.r, gold.g, gold.b, 1)
        end)
        eb:HookScript("OnEditFocusLost", function()
            do local _bn=RC:GetColor("ui","borderNormal"); con:SetBackdropBorderColor(_bn.r,_bn.g,_bn.b,_bn.a or 1) end
        end)

        eb:SetScript("OnEditFocusLost", function()
            do local _bn=RC:GetColor("ui","borderNormal"); con:SetBackdropBorderColor(_bn.r,_bn.g,_bn.b,_bn.a or 1) end
            Save()
        end)

        con:SetScript("OnMouseDown", function() eb:SetFocus() end)
        con:SetScript("OnEnter", function()
            if eb ~= _lastFocusedEB then local _bh=RC:GetColor("ui","borderHover"); con:SetBackdropBorderColor(_bh.r,_bh.g,_bh.b,1) end
        end)
        con:SetScript("OnLeave", function()
            if eb ~= _lastFocusedEB then do local _bn=RC:GetColor("ui","borderNormal"); con:SetBackdropBorderColor(_bn.r+0.3,_bn.g+0.3,_bn.b+0.3,1) end end
        end)
        con.editBox = eb
        return con
    end

    local _activePickEB = nil

    local _noteSharePopup = nil
    local function ShowNoteSharePopup(mode)
        -- Importing goes through the one import window, which takes notes
        -- and every other Readycheck export alike and says which it got.
        -- It also names the addon a notes string needs, so this does not
        -- have to be turned away when Readycheck_Features is off.
        if mode ~= "export" and RC.ShowUniversalImport then
            RC:ShowUniversalImport({ from = "notes" })
            return
        end
        -- Export/ImportBossNotes live in Readycheck_Features, but this page
        -- is drawn by the base addon and its sidebar entry carries no
        -- lodAddon, so the page renders fine with Features unticked and only
        -- these two buttons fall through to nothing. Say so instead of
        -- erroring on a nil call.
        if not (RC.ExportBossNotes and RC.ImportBossNotes) then
            -- Boss Notes initialises on a 0.5s timer, so distinguish "still
            -- starting" from "the user unticked Features".
            if RC.CompanionStatus
               and RC:CompanionStatus("Readycheck_Features") == "loading" then
                RC:Print(RCL["|cFFFFAA00Boss Notes:|r still starting up - try again in a moment."])
            else
                RC:Print(RCL["|cFFFF4444Boss Notes:|r sharing needs the Readycheck_Features addon. Enable it in your AddOns list and /reload."])
            end
            return
        end
        if not _noteSharePopup then
            local FLAT = "Interface\\Buttons\\WHITE8X8"
            local bgC = RC:GetColor("ui", "windowBackground")
            local ac  = RC:GetColor("ui", "accentGold")
            local ebBg = RC:GetColor("ui", "elementBackground")
            local hdrBg = RC:GetColor("ui", "headerBackground")
            local hdrTx = RC:GetColor("ui", "headerText")

            -- Flat window: WHITE8X8 fill, 1px black ring, 30px title bar
            -- with a gold hairline under it and a chromeless X.
            local pop = CreateFrame("Frame", "WRNoteSharePopup", UIParent)
            pop:SetSize(480, 280)
            pop:SetFrameStrata("DIALOG")
            pop:SetFrameLevel(150)
            pop:SetClampedToScreen(true)
            pop:SetMovable(true)
            pop:RegisterForDrag("LeftButton")
            pop:SetScript("OnDragStart", function(self) self:StartMoving() end)
            pop:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
            RC.UI:RegisterEscapeClose(pop)
            local popBg = pop:CreateTexture(nil, "BACKGROUND")
            popBg:SetAllPoints()
            popBg:SetTexture(FLAT)
            popBg:SetVertexColor(bgC.r, bgC.g, bgC.b, 0.97)
            RC.UI:CreateSimpleBorder(pop)
            pop:SetPoint("CENTER")
            pop:Hide()
            pop:SetToplevel(true)

            local titleBar = CreateFrame("Frame", nil, pop)
            titleBar:SetHeight(30)
            titleBar:SetPoint("TOPLEFT", pop, "TOPLEFT", 1, -1)
            titleBar:SetPoint("TOPRIGHT", pop, "TOPRIGHT", -1, -1)
            local titleBg = titleBar:CreateTexture(nil, "BACKGROUND")
            titleBg:SetAllPoints()
            titleBg:SetTexture(FLAT)
            titleBg:SetVertexColor(hdrBg.r, hdrBg.g, hdrBg.b, hdrBg.a or 1)
            local titleRule = titleBar:CreateTexture(nil, "ARTWORK")
            titleRule:SetHeight(1)
            titleRule:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 0, 0)
            titleRule:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
            titleRule:SetTexture(FLAT)
            titleRule:SetVertexColor(ac.r, ac.g, ac.b, 0.6)
            if RC.UI.ApplyHeaderArt then
                titleRule:Hide()
                RC.UI:ApplyHeaderArt(titleBar, { fill = titleBg, stepX = 160 })
            end

            local titleIcon = RC.UI:AddTitleIcon(titleBar, 16, 8)

            local titleLabel = titleBar:CreateFontString(nil, "OVERLAY")
            RC:ApplyCustomFont(titleLabel, 15, "OUTLINE")
            titleLabel:SetPoint("LEFT", titleIcon, "RIGHT", 8, 0)
            titleLabel:SetTextColor(hdrTx.r, hdrTx.g, hdrTx.b, 1)
            pop.titleLabel = titleLabel

            local closeX = RC.UI:CreateXCloseButton(titleBar, 22, function() pop:Hide() end)
            closeX:SetPoint("RIGHT", titleBar, "RIGHT", -5, 0)

            local descLabel = pop:CreateFontString(nil, "OVERLAY")
            RC:ApplyCustomFont(descLabel, 10, "NONE")
            descLabel:SetPoint("TOPLEFT", pop, "TOPLEFT", 10, -38)
            do local _c = RC:GetColor("text", "gray"); descLabel:SetTextColor(_c.r, _c.g, _c.b, _c.a) end
            pop.descLabel = descLabel

            -- Text area: flat element fill with its own 1px black ring.
            local taCon = CreateFrame("Frame", nil, pop)
            taCon:SetPoint("TOPLEFT",     pop, "TOPLEFT",     10, -56)
            taCon:SetPoint("BOTTOMRIGHT", pop, "BOTTOMRIGHT", -10, 38)
            local taBg = taCon:CreateTexture(nil, "BACKGROUND")
            taBg:SetAllPoints()
            taBg:SetTexture(FLAT)
            taBg:SetVertexColor(ebBg.r, ebBg.g, ebBg.b, ebBg.a or 1)
            RC.UI:CreateSimpleBorder(taCon)

            local _tc = RC:GetColor("text", "normal")
            local taEB = RC.UI:CreateEditBox(taCon, {
                padX = 4, padTopY = 4, padBottomY = 4, multiLine = true,
                fontSize = 9, fontFlags = "NONE",
                textColor = { _tc.r, _tc.g, _tc.b, _tc.a },
            })
            taEB:SetScript("OnEscapePressed", function() pop:Hide() end)
            pop.taEB = taEB

            local closeBtn = RC.UI:CreateStyledButton(pop, RCL["Close"], 80, 26)
            closeBtn:SetPoint("BOTTOMLEFT", pop, "BOTTOMLEFT", 10, 6)
            closeBtn:SetScript("OnClick", function() pop:Hide() end)

            local actionBtn = RC.UI:CreateStyledButton(pop, RCL["Import"], 80, 26)
            actionBtn:SetPoint("BOTTOMRIGHT", pop, "BOTTOMRIGHT", -10, 6)
            pop.actionBtn = actionBtn
            -- the 5.0 popup look (UIF_Dialogs)
            RC.UI:SkinPopup(pop, { fill = popBg, header = titleBar, title = titleLabel, close = closeX,
                dims = { descLabel }, buttons = { closeBtn }, primary = actionBtn })

            _noteSharePopup = pop
        end

        local pop = _noteSharePopup
        if not pop:IsShown() then
            RC.UI:PopIn(pop, 0.12)
        end
        pop:Raise()

        if mode == "export" then
            pop.titleLabel:SetText(RCL["Export Notes"])
            pop.descLabel:SetText(RCL["Copy the text below to share your notes with others:"])
            local str = RC:ExportBossNotes()
            pop.taEB:SetText(str ~= "" and str or RCL["(no notes to export)"])
            pop.taEB:SetFocus()
            pop.taEB:HighlightText()
            pop.actionBtn:Hide()
        else
            pop.titleLabel:SetText(RCL["Import Notes"])
            pop.descLabel:SetText(RCL["Paste an import string here, then click Import:"])
            pop.taEB:SetText("")
            pop.taEB:SetFocus()
            pop.actionBtn:Show()
            RC.UI:SetButtonText(pop.actionBtn, "Import")
            pop.actionBtn:SetScript("OnClick", function()
                local str = pop.taEB:GetText()
                local ok, result = RC:ImportBossNotes(str)
                if ok then
                    RC:Print(RCL["|cFF00FF00Boss Notes:|r Imported "] .. result .. RCL[" note(s)."])
                    pop:Hide()
                else
                    RC:Print(RCL["|cFFFF4444Boss Notes:|r Import failed - "] .. tostring(result))
                end
            end)
        end
    end

    local function BuildPerNoteToolbar(card, bcy, ebRef)
        local DOT    = 12
        local GAP    = 2
        local ROW_H  = 14
        local startX = 15

        local dotOff = math.floor((ROW_H - DOT) / 2)
        for ci, nc in ipairs(NOTE_COLORS) do
            local dot = CreateFrame("Button", nil, card, "BackdropTemplate")
            dot:SetSize(DOT, DOT)
            dot:SetPoint("TOPLEFT", card, "TOPLEFT",
                startX + (ci-1)*(DOT+GAP), bcy - dotOff)
            dot:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",
                             edgeFile="Interface\\Buttons\\WHITE8X8",edgeSize=1})
            dot:SetBackdropColor(nc.r, nc.g, nc.b, 1)
            do local _bn = RC:GetColor("ui", "borderNormal"); dot:SetBackdropBorderColor(_bn.r, _bn.g, _bn.b, _bn.a or 1) end
            local ncc = nc
            dot:SetScript("OnClick", function()
                ebRef:Insert(ncc.hex)
                ebRef:SetFocus()
            end)
            dot:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self,"ANCHOR_TOP")
                GameTooltip:SetText(ncc.label, ncc.r, ncc.g, ncc.b)
                GameTooltip:AddLine(RCL["Click to color text at cursor."], 0.8, 0.8, 0.8)
                GameTooltip:Show()
            end)
            dot:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end

        local afterDotsX = startX + #NOTE_COLORS*(DOT+GAP) + 4

        local endBtn = RC.UI:CreateStyledButton(card, "|r", 20, ROW_H)
        endBtn:SetPoint("TOPLEFT", card, "TOPLEFT", afterDotsX, bcy)
        endBtn:SetScript("OnClick", function()
            ebRef:Insert("|r"); ebRef:SetFocus()
        end)
        endBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self,"ANCHOR_TOP")
            GameTooltip:SetText(RCL["End color"], 1, 1, 1)
            GameTooltip:AddLine(RCL["Closes the current color. Clicking a new color switches without needing this."], 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        endBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        local pickBtn = RC.UI:CreateStyledButton(card, RCL["Pick"], 26, ROW_H)
        pickBtn:SetPoint("LEFT", endBtn, "RIGHT", 2, 0)
        pickBtn:SetScript("OnClick", function()
            _activePickEB = ebRef
            ColorPickerFrame:Hide()
            ColorPickerFrame.func = function()
                if _activePickEB then
                    local r, g, b = ColorPickerFrame:GetColorRGB()
                    local hex = string.format("|cFF%02X%02X%02X",
                        math.floor(r*255), math.floor(g*255), math.floor(b*255))
                    _activePickEB:Insert(hex)
                    _activePickEB:SetFocus()
                end
            end
            ColorPickerFrame.swatchFunc = ColorPickerFrame.func
            ColorPickerFrame.cancelFunc = function() end
            ColorPickerFrame.hasOpacity  = false
            ColorPickerFrame:SetColorRGB(1, 0.82, 0)
            ColorPickerFrame:Show()
        end)
        pickBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self,"ANCHOR_TOP")
            GameTooltip:SetText(RCL["Custom color"], 1, 1, 1)
            GameTooltip:AddLine(RCL["Open color picker, inserts chosen color at cursor."], 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end)
        pickBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        local markersX = afterDotsX + 20 + 2 + 26 + 8
        for mi, rm in ipairs(RAID_MARKERS) do
            local mBtn = CreateFrame("Button", nil, card, "BackdropTemplate")
            mBtn:SetSize(ROW_H + 2, ROW_H + 2)
            mBtn:SetPoint("TOPLEFT", card, "TOPLEFT",
                markersX + (mi-1)*(ROW_H+3), bcy - 1)
            mBtn:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",
                              edgeFile="Interface\\Buttons\\WHITE8X8",edgeSize=1})
            do local _cb=RC:GetColor("ui","cardBackground"); mBtn:SetBackdropColor(_cb.r,_cb.g,_cb.b,1) end
            do local _bn=RC:GetColor("ui","borderNormal"); mBtn:SetBackdropBorderColor(_bn.r,_bn.g,_bn.b,_bn.a or 1) end
            local mTex = mBtn:CreateFontString(nil,"OVERLAY")
            mTex:SetPoint("CENTER",0,0)
            mTex:SetFontObject(GameFontNormalSmall)
            RC:ApplyCustomFont(mTex, 10, "")
            mTex:SetText(rm.tex)
            local rmt = rm
            mBtn:SetScript("OnClick", function()
                ebRef:Insert(rmt.tex .. " "); ebRef:SetFocus()
            end)
            mBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self,"ANCHOR_TOP")
                GameTooltip:SetText(rmt.name .. RCL[" marker"], 1, 1, 1)
                GameTooltip:Show()
            end)
            mBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end

        bcy = bcy - ROW_H - 5

        local insLbl = RC:CreateFontString(card,"OVERLAY",nil,10)
        insLbl:SetPoint("TOPLEFT",card,"TOPLEFT",startX,bcy)
        insLbl:SetText(RCL["Insert:"])
        insLbl:SetTextColor(TEXT.medGray[1],TEXT.medGray[2],TEXT.medGray[3])
        local insX = startX + insLbl:GetStringWidth() + 4
        local xOff = 0
        for _, ins in ipairs(TEXT_INSERTS) do
            local bw = math.max(22, string.len(ins.label)*7+10)
            local btn = RC.UI:CreateStyledButton(card, ins.label, bw, ROW_H + 4)
            btn:SetPoint("TOPLEFT", card, "TOPLEFT", insX + xOff, bcy)
            xOff = xOff + bw + 3
            local inst = ins
            btn:SetScript("OnClick", function()
                ebRef:Insert(inst.text); ebRef:SetFocus()
            end)
            btn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self,"ANCHOR_TOP")
                GameTooltip:SetText(inst.tip, 1, 1, 1)
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end

        bcy = bcy - (ROW_H + 4) - 6

        return bcy
    end

    local RAID_KEY_TO_NAME = {
        naxx   = "Naxxramas",
        bwl    = "Blackwing Lair",
        mc     = "Molten Core",
        aq40   = "Temple of Ahn'Qiraj",
        zg     = "Zul'Gurub",
        onyxia = "Onyxia's Lair",
    }

    -- another game version lists its own raids, bosses and trash (RaidFlavor.lua)
    RC:OnRaidFlavor(function(raids)
        for i = #BOSS_NOTES_RAIDS, 1, -1 do BOSS_NOTES_RAIDS[i] = nil end
        for i = #TRASH_NOTES_RAIDS, 1, -1 do TRASH_NOTES_RAIDS[i] = nil end
        for _, r in ipairs(raids) do
            RAID_KEY_TO_NAME[r.code] = r.name
            local rd = RC.raidData and RC.raidData[r.name]
            local bosses = {}
            for i, b in ipairs(rd and rd.bosses or {}) do bosses[i] = b end
            BOSS_NOTES_RAIDS[#BOSS_NOTES_RAIDS + 1] = { key = r.code, label = RCL[r.abbr or r.name], bosses = bosses }
            local mobs = {}
            for _, s in ipairs(r.sections or {}) do
                for _, m in ipairs(s[2]) do mobs[#mobs + 1] = m end
            end
            if #mobs > 0 then
                TRASH_NOTES_RAIDS[#TRASH_NOTES_RAIDS + 1] = { key = r.code, label = RCL[r.abbr or r.name], mobs = mobs }
            end
        end
    end)

    local function BuildRaidProfileSwitcher(parent, frame, currentRaid, rerenderKind, yPos)
        local raidName = RAID_KEY_TO_NAME[currentRaid.key]
        if not raidName or not RC.GetRaidProfileStructure then
            return yPos
        end
        local structure = RC:GetRaidProfileStructure(raidName)
        if not structure or not structure.profiles then
            return yPos
        end

        local profileNames = {}
        for pname in pairs(structure.profiles) do
            table.insert(profileNames, pname)
        end
        table.sort(profileNames)
        local activeName = structure.activeProfile or "Default"

        local row = CreateFrame("Frame", nil, parent)
        row:SetPoint("TOPLEFT",  parent, "TOPLEFT",  10, yPos)
        row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -10, yPos)
        row:SetHeight(22)

        local lbl = RC:CreateFontString(row, "OVERLAY", nil, 10)
        lbl:SetPoint("LEFT", row, "LEFT", 5, 0)
        lbl:SetText(RCL["Raid Profile:"])
        local gc = RC:GetColor("text", "gray") or {r=0.6,g=0.6,b=0.6}
        lbl:SetTextColor(gc.r, gc.g, gc.b, 1)

        local dd = CreateFrame("Button", nil, row, "BackdropTemplate")
        dd:SetSize(160, 22)
        dd:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
        local elBG = RC:GetColor("ui", "elementBackground")
        local bNorm = RC:GetColor("ui", "borderNormal")
        local bHov  = RC:GetColor("ui", "accentGold")
        dd:SetBackdrop({
            bgFile = RC.UI.FLAT,
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        dd:SetBackdropColor(elBG.r, elBG.g, elBG.b, 1)
        dd:SetBackdropBorderColor(bNorm.r, bNorm.g, bNorm.b, 1)

        local ddTxt = RC:CreateFontString(dd, "OVERLAY", nil, 10)
        ddTxt:SetPoint("LEFT", dd, "LEFT", 8, 0)
        ddTxt:SetPoint("RIGHT", dd, "RIGHT", -18, 0)
        ddTxt:SetJustifyH("LEFT")
        ddTxt:SetText(activeName)
        local tc = RC:GetColor("text", "normal") or {r=0.85,g=0.85,b=0.85}
        ddTxt:SetTextColor(tc.r, tc.g, tc.b, 1)

        local arrow = dd:CreateTexture(nil, "ARTWORK")
        arrow:SetSize(10, 10)
        arrow:SetPoint("RIGHT", dd, "RIGHT", -8, 0)
        arrow:SetTexture("Interface\\AddOns\\Readycheck\\Media\\arrow")
        local ac = RC:GetColor("dropdown", "arrow") or RC:GetColor("ui", "accentGold")
        arrow:SetVertexColor(ac.r, ac.g, ac.b, 1)
        RC.UI:AddArrowBorder(arrow)

        dd:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(bHov.r, bHov.g, bHov.b, 1)
        end)
        dd:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(bNorm.r, bNorm.g, bNorm.b, 1)
        end)

        local menu = CreateFrame("Frame", "WRNotesProfileDropdown" .. (currentRaid.key or ""),
                                  UIParent, "UIDropDownMenuTemplate")
        local function Populate(self, level)
            local info = UIDropDownMenu_CreateInfo()
            for _, pname in ipairs(profileNames) do
                info.text  = pname
                info.value = pname
                info.checked = (pname == activeName)
                info.notCheckable = false
                info.func = function()
                    -- Boss notes are local, and this dropdown was built from
                    -- our own profile list - switch locally even mid remote edit.
                    RC:SetActiveRaidProfile(raidName, pname, true)
                    CloseDropDownMenus()
                    if RC.ShowSidebarBossNotes then
                        RC:ShowSidebarBossNotes(frame, frame.bossNotesTab)
                    end
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end
        UIDropDownMenu_Initialize(menu, Populate, "MENU")
        dd:SetScript("OnClick", function(self)
            ToggleDropDownMenu(1, nil, menu, self, 0, 0)
        end)

        return yPos - 28
    end

    local function BuildRaidTabBar(parent, frame, raids, tabStateKey, onClickTab, yPos)
        local raidKeys,raidLabels = {},{}
        for _, r in ipairs(raids) do table.insert(raidKeys,r.key); table.insert(raidLabels,r.label) end
        local numRT = #raidKeys
        local selectedRaid = frame[tabStateKey] or raidKeys[1]
        frame[tabStateKey] = selectedRaid

        local rtContainer = CreateFrame("Frame",nil,parent)
        rtContainer:SetHeight(24)
        rtContainer:SetPoint("TOPLEFT",parent,"TOPLEFT",10,yPos)
        rtContainer:SetPoint("TOPRIGHT",parent,"TOPRIGHT",-10,yPos)
        local rtBtns = {}
        for i,rk in ipairs(raidKeys) do
            local isSel=(selectedRaid==rk)
            local selBg=RC:GetColor("sidebar","buttonSelected"); local normBg=RC:GetColor("sidebar","buttonNormal")
            local hovBg=RC:GetColor("sidebar","buttonHover")
            local selTx=RC:GetColor("text","menuSelected"); local nrmTx=RC:GetColor("text","menuNormal")
            local rt=CreateFrame("Button",nil,rtContainer,"BackdropTemplate")
            rt:SetHeight(24)
            rt:SetBackdrop({bgFile=RC.UI.FLAT,edgeFile="Interface\\Buttons\\WHITE8X8",edgeSize=1})
            rt:SetBackdropColor(isSel and selBg.r or normBg.r,isSel and selBg.g or normBg.g,isSel and selBg.b or normBg.b,1)
            if isSel then local _ac=RC:GetColor("ui","borderSelected"); rt:SetBackdropBorderColor(_ac.r,_ac.g,_ac.b,1)
            else local _bn=RC:GetColor("ui","borderNormal"); rt:SetBackdropBorderColor(_bn.r,_bn.g,_bn.b,_bn.a or 1) end
            local rtTxt=RC:CreateFontString(rt,"OVERLAY",nil,9); rtTxt:SetPoint("CENTER",0,0); rtTxt:SetText(raidLabels[i])
            rtTxt:SetTextColor(isSel and selTx.r or nrmTx.r,isSel and selTx.g or nrmTx.g,isSel and selTx.b or nrmTx.b)
            rt.normBg=normBg; rt.hovBg=hovBg; rt.isSel=isSel
            RC.UI:AttachHover(rt, normBg, hovBg, { skipWhen = "isSel" })
            local rkk=rk; local tsk=tabStateKey; local oct=onClickTab
            rt:SetScript("OnClick",function() frame[tsk]=rkk; RC:ShowSidebarBossNotes(frame,oct) end)
            rtBtns[i]=rt
        end
        local function RecalcRT()
            local w=rtContainer:GetWidth(); if not w or w<=0 then return end
            local spacing=3; local tw=math.floor((w-(numRT-1)*spacing)/numRT)
            for i,rt in ipairs(rtBtns) do
                rt:SetWidth(tw)
                if i==1 then rt:SetPoint("LEFT",rtContainer,"LEFT",0,0)
                else rt:SetPoint("LEFT",rtBtns[i-1],"RIGHT",spacing,0) end
            end
        end
        RecalcRT(); rtContainer:SetScript("OnSizeChanged",RecalcRT)
        local currentRaid = nil
        for _,r in ipairs(raids) do if r.key==selectedRaid then currentRaid=r; break end end
        return currentRaid, yPos - 32
    end

    ------------------------------------------------------------------
    -- THE NOTE BOX, drawn the way the on-screen note is (BossNotes.lua in
    -- Readycheck_Features): flat window fill at the note opacity, a 1px
    -- black edge, white outlined text, sized to the longest line between
    -- 100 and 520 px. The pane preview draws through these; the runtime
    -- can too (see the consumables patch notes), and once it does it sets
    -- RC.BOSS_NOTES_STYLE_LIVE and the page offers the extra looks below
    -- (font face, colours, entrance and exit).
    -- db.bossNotes fields (nil = today's look): font (font spec; the size
    -- stays fontSize), textColor, bgColor, borderColor, showAnim, hideAnim.
    ------------------------------------------------------------------
    RC.BOSS_NOTE_ANIM_DEFAULTS = { style = "none", duration = 0.3 }
    local BN_MAX_W, BN_MIN_W = 520, 100

    function RC:BuildBossNotesBox(parent)
        local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        f:SetSize(300, 40)
        local flat = (RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8"
        f:SetBackdrop({ bgFile = flat, edgeFile = flat, edgeSize = 1 })
        local nt = f:CreateFontString(nil, "OVERLAY")
        nt:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -6)
        nt:SetJustifyH("LEFT")
        nt:SetJustifyV("TOP")
        nt:SetWordWrap(true)
        f.noteText = nt
        return f
    end

    function RC:BossNotesFontDefaults(db)
        return { size = (db and db.fontSize) or 14, outline = "OUTLINE", shadow = true }
    end

    -- Fill, edge, font and colour, then the two-pass size to the text.
    function RC:StyleBossNotesBox(f, text, db)
        db = db or self.db.bossNotes or {}
        local spec = type(db.font) == "table" and db.font or nil
        local fspec = spec and { face = spec.face, outline = spec.outline, shadow = spec.shadow } or nil
        local defaults = self:BossNotesFontDefaults(db)
        self:ApplyFontSpec(f.noteText, fspec, defaults)
        local tc = type(db.textColor) == "table" and db.textColor or self:GetColor("text", "white")
        f.noteText:SetTextColor(tc.r, tc.g, tc.b, tc.a or 1)
        if db.showBackground ~= false then
            local bg = type(db.bgColor) == "table" and db.bgColor or self:GetColor("ui", "windowBackground")
            local bd = type(db.borderColor) == "table" and db.borderColor or { r = 0, g = 0, b = 0, a = 1 }
            f:SetBackdropColor(bg.r, bg.g, bg.b, (db.opacity or 0.85) * 0.9)
            f:SetBackdropBorderColor(bd.r, bd.g, bd.b, bd.a or 1)
        else
            f:SetBackdropColor(0, 0, 0, 0)
            f:SetBackdropBorderColor(0, 0, 0, 0)
        end
        local nt = f.noteText
        -- The box is sized around its text, so the text is not placed by
        -- an anchor (it would leave the box): bossNotes.layout.padding is
        -- the room at the sides (top / bottom 2 less: 8 / 6 as always) and
        -- bossNotes.anchors.text.justify the lines' alignment. Nothing set
        -- = the same sums as before.
        local px, py = 8, 6
        local lay = type(db.layout) == "table" and db.layout or nil
        if lay and tonumber(lay.padding) then
            px = math_max(0, tonumber(lay.padding))
            py = math_max(0, px - 2)
        end
        local anc = type(db.anchors) == "table" and db.anchors or nil
        local jh = anc and type(anc.text) == "table" and anc.text.justify or nil
        if jh or f._bnJustified then
            nt:SetJustifyH(jh or "LEFT")
            f._bnJustified = jh ~= nil
        end
        nt:ClearAllPoints()
        nt:SetPoint("TOPLEFT", f, "TOPLEFT", px, -py)
        nt:SetWordWrap(false)
        nt:SetWidth(BN_MAX_W + 400)
        local maxLineW = 0
        for line in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
            nt:SetText(line ~= "" and line or " ")
            local lw = nt:GetStringWidth() or 0
            if lw > maxLineW then maxLineW = lw end
        end
        local w = math_max(BN_MIN_W, math_min(BN_MAX_W, maxLineW + px * 2))
        nt:SetWordWrap(true)
        nt:SetWidth(w - px * 2)
        nt:SetText(text or "")
        f:SetWidth(w)
        f:SetHeight(math_max(28, (nt:GetStringHeight() or 14) + py * 2))
    end

    local BN_SAMPLES = {
        boss = "|cffff4040Tanks:|r swap on 3 stacks\n|cff40c0ffHealers:|r save cooldowns for phase 2\nEveryone: spread 10 yards for the bombs",
        trash = "Kick the |cffffd100Necro Knight|r frost blasts",
        short = "Pull at 10",
    }
    local BN_W, BN_H = 340, 62   -- update sizes the canvas to the note

    -- the note's padding and alignment (module level: the pooled pickers
    -- get every function through their opts)
    local function BNRoot() RC.db.bossNotes = RC.db.bossNotes or {} return RC.db.bossNotes end
    local function BNLayoutChanged()
        RC:SaveConfigurationToProfile()
        if RC.UpdateBossNotes then RC:UpdateBossNotes() end
        local f = RC.bossNotes and RC.bossNotes.frame
        if f and f:IsShown() and f._lastStyledNote and RC.StyleBossNotesBox then
            RC:StyleBossNotesBox(f, f._lastStyledNote, RC.db.bossNotes)
        end
    end
    local BN_LAYOUT_FIELDS = { padding = true }
    local BN_LAYOUT_DEFAULTS = { padding = 8 }
    local BN_ALIGN_ITEMS = { { key = "LEFT", label = RCL["Left"] }, { key = "CENTER", label = RCL["Center"] }, { key = "RIGHT", label = RCL["Right"] } }

    local function DeclareBossNotesPreview(self)
        if RC.CustomPick then
            RC.CustomPick.SetHandler("consumables.bossNotes", function(k)
                if k ~= "bnText" then return end
                local cf = RC.sidebarConfigFrame and RC.sidebarConfigFrame.compatFrame
                if cf then RC:ShowSidebarBossNotes(cf, "text") end
            end)
        end
        return self.UI:DeclarePreview({
            key = "consumables.bossNotes", title = RCL["Boss note"],
            width = BN_W, height = BN_H,
            build = function(canvas, P)
                local f = RC:BuildBossNotesBox(canvas)
                f:SetPoint("CENTER", canvas, "CENTER", 0, 0)
                P.store.box, P.store.token = f, 0
                -- a click on the note opens the Text tab on its padding / alignment
                RC.UI:TagElement(f.noteText, "bnText")
                RC.UI:PickOnClick(f, "consumables.bossNotes")
            end,
            update = function(canvas, P)
                local st = P.store
                local db = RC.db.bossNotes or {}
                if not RC.Motion.IsPlaying(st.box) then
                    RC:StyleBossNotesBox(st.box, BN_SAMPLES[P.mode or "boss"] or BN_SAMPLES.boss, db)
                    -- the canvas is the note at 100% (the strip scales it); its
                    -- own scale shows smaller, never above 1, as before
                    local sc = math_min(1, db.scale or 1)
                    st.box:SetScale(sc)
                    P.Resize(st.box:GetWidth() + 6, st.box:GetHeight() + 6)
                end
            end,
            replay = function(canvas, P)
                local M = RC.Motion
                local st = P.store
                local f = st.box
                local db = RC.db.bossNotes or {}
                st.token = st.token + 1
                local t = st.token
                M.Stop(f)
                f:Hide()
                local inSpec = M.Normalize(db.showAnim, RC.BOSS_NOTE_ANIM_DEFAULTS)
                M.Show(f, inSpec)
                C_Timer.After(M.Duration(inSpec.duration) + M.Duration(inSpec.delay) + 1.4, function()
                    if t ~= st.token or not f:IsVisible() then return end
                    local outSpec = M.Normalize(db.hideAnim, RC.BOSS_NOTE_ANIM_DEFAULTS)
                    M.Hide(f, outSpec)
                    C_Timer.After(M.Duration(outSpec.duration) + M.Duration(outSpec.delay) + 0.4, function()
                        if t ~= st.token then return end
                        M.Stop(f)
                        if canvas:IsVisible() then f:Show() end
                    end)
                end)
            end,
            modes = { { id = "boss", label = RCL["Boss note"] }, { id = "trash", label = RCL["Trash note"] }, { id = "short", label = RCL["One line"] } },
            modesLabel = RCL["Show"],
        })
    end

    function RC:ShowSidebarBossNotes(frame, selectedTab)
        local isTabSwitch = (selectedTab ~= nil)
        self:ClearSidebarContent(self.sidebarConfigFrame, isTabSwitch)
        -- the note box, drawn as the on-screen note is
        local P = DeclareBossNotesPreview(self)
        selectedTab = selectedTab or frame.bossNotesTab or "behavior"
        if selectedTab == "notes" then selectedTab = "bosses" end
        -- the old General tab (search aliases, saved state) is Behavior now
        if selectedTab == "general" then selectedTab = "behavior" end
        frame.bossNotesTab = selectedTab

        local parent = frame.scrollChild
        local yPos = -15

        local headerFrame, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Boss & Trash Notes"],
            RCL["Notes shown when targeting bosses or specific trash mobs"], "Interface\\Icons\\INV_Misc_Note_01")
        yPos = newY

        if not self.db.bossNotes then self.db.bossNotes = {} end
        local bnDef = {
            enabled=true,locked=true,xOffset=0,yOffset=150,scale=1.0,opacity=0.85,
            fontSize=14,showBackground=true,showForTrash=true,
            lingerDuration=0,notes={},
            trashNotesByRaid={},trashNotesByPack={},
            useNameplateScan=true,nameplateScanInterval=0.5,
        }
        for k, v in pairs(bnDef) do
            if self.db.bossNotes[k] == nil then self.db.bossNotes[k] = v end
        end
        if type(self.db.bossNotes.notes) ~= "table" then self.db.bossNotes.notes = {} end
        if type(self.db.bossNotes.trashNotesByRaid) ~= "table" then self.db.bossNotes.trashNotesByRaid = {} end
        if type(self.db.bossNotes.trashNotesByPack) ~= "table" then self.db.bossNotes.trashNotesByPack = {} end
        if type(self.db.bossNotes.bossNoteAdded)    ~= "table" then self.db.bossNotes.bossNoteAdded    = {} end
        local db = self.db.bossNotes
        local function Save() RC:SaveConfigurationToProfile() end

        -- Finds a note stored under an old case/whitespace-mismatched variant
        -- of exactKey and migrates it in place (renames map[k] -> map[exactKey]).
        local function ResolveScopedNoteKey(map, exactKey)
            if type(map) ~= "table" or not exactKey then return exactKey end
            if map[exactKey] ~= nil and map[exactKey] ~= "" then return exactKey end
            local want = exactKey:lower():gsub("%s+", " ")
            for k, v in pairs(map) do
                if type(k) == "string" and v and v ~= "" and k ~= exactKey then
                    if k:lower():gsub("%s+", " ") == want then
                        map[exactKey] = v
                        map[k] = nil
                        return exactKey
                    end
                end
            end
            return exactKey
        end

        local function ProfileKeyForBoss(currentRaid, bossName)
            if not currentRaid or not currentRaid.key then return bossName, nil end
            local raidLong = RAID_KEY_TO_NAME[currentRaid.key]
            if not raidLong or not RC.GetActiveProfileNameForRaid then
                return bossName, nil
            end
            local profileName = RC:GetActiveProfileNameForRaid(raidLong)
            if not profileName or profileName == "" then return bossName, nil end
            return bossName .. "|" .. raidLong .. "|" .. profileName, bossName
        end
        local function ProfileKeyForRaidShort(currentRaid)
            if not currentRaid or not currentRaid.key then return nil, nil end
            local rk = currentRaid.key
            local raidLong = RAID_KEY_TO_NAME[rk]
            if not raidLong or not RC.GetActiveProfileNameForRaid then
                return rk, nil
            end
            local profileName = RC:GetActiveProfileNameForRaid(raidLong)
            if not profileName or profileName == "" then return rk, nil end
            return rk .. "|" .. profileName, rk
        end

        local _, newTabY = self.UI:CreateTabGroup(parent, {
            y = yPos,
            tabs = {
                { key = "behavior", label = RCL["Behavior"] },
                { key = "bosses",   label = RCL["Boss Notes"] },
                { key = "trash",    label = RCL["Trash Notes"] },
                { key = "look",     label = RCL["Look"] },
                { key = "text",     label = RCL["Text"] },
                { key = "animation", label = RCL["Animation"] },
                { key = "sound",    label = RCL["Sound"] },
                { key = "position", label = RCL["Position"] },
            },
            selected = selectedTab,
            onClick = function(tk)
                frame.bossNotesTab = tk
                RC:ShowSidebarBossNotes(frame, tk)
            end,
            advance = 34,
        })
        yPos = newTabY

        local function Live() if RC.UpdateBossNotes then RC:UpdateBossNotes() end end
        local function Desc(card, y, text)
            return (RC.UI:CreateHelpLine(card, 15, y, text, { gap = 6 }))
        end
        local function AddSlider(card, cardY, lbl, minV, maxV, cur, step, fmt, onChange)
            local lbFnt = self:CreateFontString(card, "OVERLAY", nil, 10)
            lbFnt:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
            lbFnt:SetText(lbl) lbFnt:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            local sl = self.UI:CreateSlider(card, minV, maxV, cur, step)
            sl:SetPoint("TOPLEFT", card, "TOPLEFT", 95, cardY + 5) sl:SetWidth(140)
            sl.Text:SetText(fmt(cur))
            sl:SetScript("OnValueChanged", function(s, v) sl.Text:SetText(fmt(v)) onChange(v) end)
            sl:SetScript("OnMouseUp", function() Save() end)
            return cardY - 32
        end
        -- the extra looks need the runtime to draw through StyleBossNotesBox
        local styleLive = RC.BOSS_NOTES_STYLE_LIVE

        if selectedTab == "behavior" then
            local card = self:CreateSettingsCard(parent, yPos, RCL["Display"])
            local cardY = -35

            local enableCb = self.UI:CreateCheckbox(card, RCL["Enable Boss Notes"], db.enabled)
            enableCb:SetPoint("TOPLEFT",card,"TOPLEFT",15,cardY)
            enableCb:SetScript("OnClick",function(cb)
                db.enabled=cb:GetChecked();RC:ForceCheckboxUpdate(cb,db.enabled)
                Live(); Save()
            end)
            cardY = cardY - 26
            local enableMark = self.UI:MarkCard(card)

            local trashCb = self.UI:CreateCheckbox(card, RCL["Show trash note in raid instances"], db.showForTrash)
            trashCb:SetPoint("TOPLEFT",card,"TOPLEFT",15,cardY)
            trashCb:SetScript("OnClick",function(cb)
                db.showForTrash=cb:GetChecked();RC:ForceCheckboxUpdate(cb,db.showForTrash);Save()
            end)
            cardY = cardY - 32

            cardY = AddSlider(card, cardY, RCL["Linger:"], 0, 30, db.lingerDuration or 0, 1,
                function(v)
                    local n = math.floor(v)
                    return n == 0 and RCL["Off (hide immediately)"] or (n .. RCL["s after detarget"])
                end,
                function(v) db.lingerDuration = math.floor(v) end)
            cardY = Desc(card, cardY, RCL["Linger: how long the note stays visible after you detarget or the boss dies."])
            cardY = cardY - 4
            self.UI:BindDependents(enableCb, self.UI:CardSince(card, enableMark))
            card:SetContentHeight(math.abs(cardY))

            yPos = yPos - card:GetHeight() - 15
        end

        if selectedTab == "look" then
            local card = self:CreateSettingsCard(parent, yPos, RCL["Note box"])
            local cardY = -35
            local bgCb = self.UI:CreateCheckbox(card, RCL["Show background"], db.showBackground ~= false)
            bgCb:SetPoint("TOPLEFT",card,"TOPLEFT",15,cardY)
            bgCb:SetScript("OnClick",function(cb)
                db.showBackground=cb:GetChecked();RC:ForceCheckboxUpdate(cb,db.showBackground)
                Live(); Save()
            end)
            cardY = cardY - 32
            local bgMark = self.UI:MarkCard(card)
            cardY = AddSlider(card, cardY, RCL["Opacity:"], 0.0, 1.0, db.opacity or 0.85, 0.05,
                function(v) return string.format("%.0f%%",math.floor(v*20)/20*100) end,
                function(v) db.opacity=math.floor(v*20)/20; Live() end)
            cardY = Desc(card, cardY, RCL["How solid the box behind the note is."])
            if styleLive then
                local function Pick(key, label, default)
                    local cp = self.UI:CreateColorPicker(card, {
                        label = label, width = 420, alpha = true,
                        get = function() return db[key] end,
                        set = function(r, g, b, a) db[key] = { r = r, g = g, b = b, a = a or 1 } Save() Live() end,
                        default = default,
                        isChanged = function() return type(db[key]) == "table" end,
                        reset = function() db[key] = nil Save() Live() end,
                    })
                    cp:SetPoint("TOPLEFT", card, "TOPLEFT", 10, cardY)
                    cardY = cardY - 28
                end
                Pick("bgColor", RCL["Background colour"], RC:GetColor("ui", "windowBackground"))
                Pick("borderColor", RCL["Edge colour"], { r = 0, g = 0, b = 0, a = 1 })
            end
            cardY = cardY - 4
            -- the box's opacity and colours only show with the box shown
            self.UI:BindDependents(bgCb, self.UI:CardSince(card, bgMark))
            card:SetContentHeight(math.abs(cardY))

            yPos = yPos - card:GetHeight() - 15
        end

        if selectedTab == "text" then
            local card = self:CreateSettingsCard(parent, yPos, RCL["Note text"])
            local cardY = -35
            if styleLive then
                -- the size is the note's long-standing fontSize; the rest
                -- lives in db.bossNotes.font
                local fp = self.UI:CreateFontPicker(card, {
                    label = RCL["Font"], width = 420,
                    get = function()
                        local f = type(db.font) == "table" and db.font or {}
                        return { face = f.face, outline = f.outline, shadow = f.shadow, size = db.fontSize or 14 }
                    end,
                    set = function(spec)
                        db.fontSize = spec.size or db.fontSize
                        db.font = { face = spec.face, outline = spec.outline, shadow = spec.shadow }
                        Save() Live()
                    end,
                    defaults = RC:BossNotesFontDefaults(db), minSize = 8, maxSize = 32,
                    sample = "Tanks: swap on 3 stacks",
                })
                fp:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
                cardY = cardY - fp:GetHeight() - 8
                local cp = self.UI:CreateColorPicker(card, {
                    label = RCL["Text colour"], width = 420,
                    get = function() return db.textColor end,
                    set = function(r, g, b) db.textColor = { r = r, g = g, b = b, a = 1 } Save() Live() end,
                    default = RC:GetColor("text", "white"),
                    isChanged = function() return type(db.textColor) == "table" end,
                    reset = function() db.textColor = nil Save() Live() end,
                })
                cp:SetPoint("TOPLEFT", card, "TOPLEFT", 10, cardY)
                cardY = cardY - 28
                cardY = Desc(card, cardY, RCL["Colour codes typed into a note still win over the text colour."])
                card:SetContentHeight(math.abs(cardY))
                yPos = yPos - card:GetHeight() - 15
                -- padding and alignment instead of a position: the box
                -- grows and shrinks around its text
                card = self:CreateSettingsCard(parent, yPos, RCL["Padding and alignment"])
                cardY = -35
                cardY = Desc(card, cardY, RCL["The box sizes itself around the note, so the text has no position of its own: set the room around it and how its lines line up."])
                local lg, ls = self.UI:CustomAccess(BNRoot, "layout", nil, BNLayoutChanged)
                local lp = self.UI:CreateLayoutPicker(card, { label = RCL["Room around the text"], width = 420, key = "bnText",
                    get = lg, set = ls, fields = BN_LAYOUT_FIELDS, defaults = BN_LAYOUT_DEFAULTS })
                lp:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
                cardY = cardY - lp:GetHeight() - 6
                cardY = Desc(card, cardY, RCL["At the sides; the top and bottom get 2 px less (8 and 6 as it always was)."])
                local ag, as = self.UI:CustomAccess(BNRoot, "anchors", "text", BNLayoutChanged)
                local cur = ag()
                self.UI:CreateSegmentedControl(card, { x = 15, y = cardY, height = 22, label = RCL["Text align"],
                    items = BN_ALIGN_ITEMS, selected = (cur and cur.justify) or "LEFT",
                    onSelect = function(k) as((k ~= "LEFT") and { justify = k } or nil) end })
                cardY = cardY - 34
                if RC.CustomPick and RC.CustomPick.RegisterGroup then RC.CustomPick.RegisterGroup("bnText", card) end
            else
                cardY = AddSlider(card, cardY, RCL["Font Size:"], 8, 24, db.fontSize or 14, 1,
                    function(v) return math.floor(v) .. " pt" end,
                    function(v) db.fontSize = math.floor(v); Live() end)
                cardY = Desc(card, cardY, RCL["The note uses the Readycheck font (Appearance > Fonts)."])
            end
            card:SetContentHeight(math.abs(cardY))
            yPos = yPos - card:GetHeight() - 15
        end

        if selectedTab == "animation" then
            local card = self:CreateSettingsCard(parent, yPos, RCL["Note animation"])
            local cardY = -35
            if styleLive then
                local function Set(which, spec) db[which] = spec Save() if P then P.Replay() end end
                local inP = self.UI:CreateAnimationPicker(card, {
                    label = RCL["When it appears"], width = 460, how = "in", defaults = RC.BOSS_NOTE_ANIM_DEFAULTS,
                    get = function() return db.showAnim end, set = function(spec) Set("showAnim", spec) end,
                })
                inP:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
                cardY = cardY - inP:GetHeight() - 14
                local outP = self.UI:CreateAnimationPicker(card, {
                    label = RCL["When it goes"], width = 460, how = "out", defaults = RC.BOSS_NOTE_ANIM_DEFAULTS,
                    get = function() return db.hideAnim end, set = function(spec) Set("hideAnim", spec) end,
                })
                outP:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
                cardY = cardY - outP:GetHeight() - 8
                cardY = Desc(card, cardY, RCL["Appearance > Motion can turn every animation off or speed them all up."])
            else
                cardY = Desc(card, cardY, RCL["The note appears and goes at once. Entrance and exit animations come with the next update of the note display."])
            end
            card:SetContentHeight(math.abs(cardY))
            yPos = yPos - card:GetHeight() - 15
        end

        if selectedTab == "sound" then
            local card = self:CreateSettingsCard(parent, yPos, RCL["Read aloud"])
            local cardY = -35
            if db.ttsEnabled == nil then db.ttsEnabled = false end
            if db.ttsTrigger == nil then db.ttsTrigger = "encounter_start" end

            local ttsCb = self.UI:CreateCheckbox(card, RCL["Read note aloud (Text-to-Speech)"], db.ttsEnabled)
            ttsCb:SetPoint("TOPLEFT",card,"TOPLEFT",15,cardY)
            ttsCb:SetScript("OnClick",function(cb)
                db.ttsEnabled = cb:GetChecked()
                self:ForceCheckboxUpdate(cb,db.ttsEnabled); Save()
            end)
            cardY = cardY - 24

            local ttsHint = self:CreateFontString(card,"OVERLAY",nil,10)
            ttsHint:SetPoint("TOPLEFT",card,"TOPLEFT",35,cardY)
            ttsHint:SetWidth(card:GetWidth()-50)
            ttsHint:SetText(RCL["Uses OS text-to-speech to speak the note when it appears. Volume set in Reminder Settings > Sound."])
            ttsHint:SetTextColor(TEXT.gray[1],TEXT.gray[2],TEXT.gray[3])
            ttsHint:SetJustifyH("LEFT")
            cardY = cardY - ttsHint:GetStringHeight() - 6

            local trigLbl = self:CreateFontString(card,"OVERLAY",nil,10)
            trigLbl:SetPoint("TOPLEFT",card,"TOPLEFT",15,cardY)
            trigLbl:SetText(RCL["Speak when:"])
            trigLbl:SetTextColor(TEXT.light[1],TEXT.light[2],TEXT.light[3])
            cardY = cardY - 20

            local triggers = {
                {key="encounter_start", label=RCL["Encounter starts (once per boss)"]},
                {key="target",          label=RCL["Note first appears (any target change)"]},
            }
            for _, t in ipairs(triggers) do
                local isSel = (db.ttsTrigger == t.key)
                local rb = self.UI:CreateCheckbox(card, t.label, isSel)
                rb:SetPoint("TOPLEFT",card,"TOPLEFT",28,cardY)
                rb:SetScript("OnClick",function(cb)
                    db.ttsTrigger = t.key
                    self:ForceCheckboxUpdate(cb, true)
                    for _, t2 in ipairs(triggers) do
                        if t2.key ~= t.key and t2._cb then
                            self:ForceCheckboxUpdate(t2._cb, false)
                        end
                    end
                    Save()
                end)
                t._cb = rb
                cardY = cardY - 22
            end
            cardY = cardY - 4
            card:SetContentHeight(math.abs(cardY))
            yPos = yPos - card:GetHeight() - 15
        end

        if selectedTab == "position" then
            local card = self:CreateSettingsCard(parent, yPos, RCL["Position"])
            local cardY = -35
            local lockCb = self.UI:CreateCheckbox(card, RCL["Locked (click-through)"], db.locked)
            lockCb:SetPoint("TOPLEFT",card,"TOPLEFT",15,cardY)
            lockCb:SetScript("OnClick",function(cb)
                db.locked=cb:GetChecked();RC:ForceCheckboxUpdate(cb,db.locked)
                if RC.bossNotes and RC.bossNotes.frame then
                    RC.bossNotes.frame:EnableMouse(not db.locked)
                end; Save()
            end)
            cardY = cardY - 32
            cardY = AddSlider(card, cardY, RCL["Y Offset:"], -400, 400, db.yOffset or 150, 10,
                function(v) return math.floor(v/10)*10 .."px" end,
                function(v)
                    local f = RC.bossNotes and RC.bossNotes.frame
                    if f and RC.Position.IsBound(f) then
                        RC.Position.SetFrame(f, db.xOffset or 0, math.floor(v/10)*10, true)
                    else
                        db.yOffset=math.floor(v/10)*10
                    end
                    if RC.ApplyBossNotesPosition then RC:ApplyBossNotesPosition() end
                end)
            cardY = Desc(card, cardY, RCL["Unlock and drag to reposition. Y Offset moves from screen center."])
            card:SetContentHeight(math.abs(cardY))
            yPos = yPos - card:GetHeight() - 15
        end

        if selectedTab == "bosses" then
            local expBtn = self.UI:CreateStyledButton(parent, RCL["Export Notes"], 120, 26)
            expBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, yPos)
            expBtn:SetScript("OnClick", function() ShowNoteSharePopup("export") end)
            expBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self,"ANCHOR_TOP")
                GameTooltip:SetText(RCL["Export Notes"],1,1,1)
                GameTooltip:AddLine(RCL["Copy your notes to share with others."],0.8,0.8,0.8)
                GameTooltip:Show()
            end)
            expBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            local impBtn = self.UI:CreateStyledButton(parent, RCL["Import Notes"], 120, 26)
            impBtn:SetPoint("LEFT", expBtn, "RIGHT", 6, 0)
            impBtn:SetScript("OnClick", function() ShowNoteSharePopup("import") end)
            impBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self,"ANCHOR_TOP")
                GameTooltip:SetText(RCL["Import Notes"],1,1,1)
                GameTooltip:AddLine(RCL["Paste a friend's export string to import their notes."],0.8,0.8,0.8)
                GameTooltip:Show()
            end)
            impBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
            yPos = yPos - 34

            -- Profile switcher renders above the raid tab bar, so it must use last
            -- frame's raid tab; BuildRaidTabBar (below) is what actually resolves
            -- and stores the selection this render will use for the note cards.
            local prevBossRaidKey = frame.bossNotesRaidTab or (BOSS_NOTES_RAIDS[1] and BOSS_NOTES_RAIDS[1].key)
            local prevBossRaid = nil
            for _, r in ipairs(BOSS_NOTES_RAIDS) do
                if r.key == prevBossRaidKey then prevBossRaid = r; break end
            end
            if prevBossRaid then
                yPos = BuildRaidProfileSwitcher(parent, frame, prevBossRaid, "bosses", yPos)
            end

            local currentRaid, newY = BuildRaidTabBar(parent, frame, BOSS_NOTES_RAIDS, "bossNotesRaidTab", "bosses", yPos)
            yPos = newY

            if currentRaid then
                if type(db.bossNoteAdded) ~= "table" then db.bossNoteAdded = {} end
                local raidLongB = RAID_KEY_TO_NAME[currentRaid.key]
                local profB = (raidLongB and RC.GetActiveProfileNameForRaid
                    and RC:GetActiveProfileNameForRaid(raidLongB)) or "Default"
                local function BossAddedKey(bn2)
                    return currentRaid.key .. "|" .. bn2 .. "|" .. profB
                end
                local configuredB, availableB = {}, {}
                for _, bossName in ipairs(currentRaid.bosses) do
                    local sKey, fKey = ProfileKeyForBoss(currentRaid, bossName)
                    sKey = ResolveScopedNoteKey(db.notes, sKey)
                    local hasText = (db.notes[sKey] and db.notes[sKey] ~= "")
                        or (fKey and db.notes[fKey] and db.notes[fKey] ~= "")
                    if db.bossNoteAdded[BossAddedKey(bossName)] or hasText then
                        configuredB[#configuredB + 1] = bossName
                    else
                        availableB[#availableB + 1] = bossName
                    end
                end

                local bossCard = self:CreateSettingsCard(parent,yPos,currentRaid.label..RCL[" bosses"])
                local bcy = -35
                local cardInnerW = bossCard:GetWidth() - 30

                if #availableB > 0 then
                    local addLblB = self:CreateFontString(bossCard, "OVERLAY", nil, 10)
                    addLblB:SetPoint("TOPLEFT", bossCard, "TOPLEFT", 15, bcy - 5)
                    addLblB:SetText(RCL["Add boss:"])
                    addLblB:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
                    local addDDB = self.UI:CreateScrollableDropdown(bossCard, 220, RCL["Pick a boss..."], 10)
                    addDDB:SetPoint("TOPLEFT", bossCard, "TOPLEFT", 80, bcy)
                    local itemsB = {}
                    for _, bossName in ipairs(availableB) do
                        itemsB[#itemsB + 1] = { text = bossName, value = bossName }
                    end
                    addDDB:SetItems(itemsB, function(value)
                        db.bossNoteAdded[BossAddedKey(value)] = true
                        RC:SaveConfigurationToProfile()
                        RC:ShowSidebarBossNotes(frame, "bosses")
                    end)
                    bcy = bcy - 34
                end

                if #configuredB == 0 then
                    local emptyB = self:CreateFontString(bossCard, "OVERLAY", nil, 10)
                    emptyB:SetPoint("TOPLEFT", bossCard, "TOPLEFT", 15, bcy)
                    emptyB:SetText(RCL["No boss notes yet - add one above."])
                    emptyB:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                    bcy = bcy - 20
                end

                for _,bossName in ipairs(configuredB) do
                    local bn = bossName
                    local nameY = bcy
                    local bossKey, bossFallbackKey = ProfileKeyForBoss(currentRaid, bossName)
                    bossKey = ResolveScopedNoteKey(db.notes, bossKey)
                    local con = CreateNoteEditBox(bossCard, db, bossKey, cardInnerW, 65, bossFallbackKey)
                    local ebRef = con.editBox
                    local bl = self:CreateFontString(bossCard,"OVERLAY",nil,10)
                    bl:SetPoint("TOPLEFT", bossCard, "TOPLEFT", 15, nameY)
                    bl:SetWidth(cardInnerW - 55); bl:SetText(bossName); bl:SetJustifyH("LEFT")
                    bl:SetTextColor(TEXT.light[1],TEXT.light[2],TEXT.light[3])
                    local prevB = self.UI:CreateStyledButton(bossCard, RCL["Show"], 44, 18)
                    prevB:SetPoint("TOPRIGHT", bossCard, "TOPRIGHT", -38, nameY)
                    prevB._isShowing = false
                    local remB = RC.UI:CreateXCloseButton(bossCard, 16, function()
                        local sKey = ProfileKeyForBoss(currentRaid, bn)
                        sKey = ResolveScopedNoteKey(db.notes, sKey)
                        db.notes[sKey] = nil
                        db.bossNoteAdded[BossAddedKey(bn)] = nil
                        RC:SaveConfigurationToProfile()
                        RC:ShowSidebarBossNotes(frame, "bosses")
                    end)
                    remB:SetPoint("TOPRIGHT", bossCard, "TOPRIGHT", -15, nameY)
                    remB:SetScript("OnEnter", function(sf)
                        GameTooltip:SetOwner(sf, "ANCHOR_RIGHT")
                        GameTooltip:SetText(RCL["Remove this profile's note for "] .. bn, 1, 0.82, 0)
                        GameTooltip:AddLine(RCL["Other raid profiles keep their own notes."], 0.8, 0.8, 0.8)
                        GameTooltip:Show()
                    end)
                    remB:SetScript("OnLeave", function() GameTooltip:Hide() end)
                    local afterToolbar = BuildPerNoteToolbar(bossCard, bcy - 19, ebRef)
                    con:SetPoint("TOPLEFT",  bossCard, "TOPLEFT",   15, afterToolbar)
                    con:SetPoint("TOPRIGHT", bossCard, "TOPRIGHT", -15, afterToolbar)
                    prevB:SetScript("OnClick", function()
                        local note = ebRef:GetText()
                        if not note or note == "" then
                            note = db.notes[bossKey] or (bossFallbackKey and db.notes[bossFallbackKey]) or ""
                        end
                        if prevB._isShowing then
                            if RC.HideBossNotesPreview then RC:HideBossNotesPreview() end
                            prevB._isShowing = false; RC.UI:SetButtonText(prevB, "Show")
                        elseif note ~= "" and RC.PreviewBossNoteText then
                            RC:PreviewBossNoteText(note); prevB._isShowing = true; RC.UI:SetButtonText(prevB, "Hide")
                        end
                    end)
                    ebRef:SetScript("OnTextChanged", function(self)
                        if prevB._isShowing then
                            local t = self:GetText()
                            if t and t ~= "" and RC.PreviewBossNoteText then
                                RC:PreviewBossNoteText(t)
                            end
                        end
                    end)
                    prevB:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self,"ANCHOR_RIGHT"); GameTooltip:SetText(RCL["Show/hide: "] .. bn, 1, 0.82, 0); GameTooltip:Show()
                    end)
                    prevB:SetScript("OnLeave", function() GameTooltip:Hide() end)
                    bcy = afterToolbar - 70
                end
                bcy = bcy - 4
                bossCard:SetContentHeight(math.abs(bcy))
                yPos = yPos - bossCard:GetHeight() - 15
            end

        elseif selectedTab == "trash" then
            -- Same last-frame-tab ordering as the boss switcher above.
            local prevTrashRaidKey = frame.trashNotesRaidTab or (TRASH_NOTES_RAIDS[1] and TRASH_NOTES_RAIDS[1].key)
            local prevTrashRaid = nil
            for _, r in ipairs(TRASH_NOTES_RAIDS) do
                if r.key == prevTrashRaidKey then prevTrashRaid = r; break end
            end
            if prevTrashRaid then
                yPos = BuildRaidProfileSwitcher(parent, frame, prevTrashRaid, "trash", yPos)
            end

            local currentRaid, newY = BuildRaidTabBar(parent, frame, TRASH_NOTES_RAIDS, "trashNotesRaidTab", "trash", yPos)
            yPos = newY

            if currentRaid then
                if type(db.trashNotesByRaid) ~= "table" then db.trashNotesByRaid = {} end
                if type(db.trashNotesByPack) ~= "table" then db.trashNotesByPack = {} end
                if not db.trashNotesByPack[currentRaid.key] then
                    db.trashNotesByPack[currentRaid.key] = {}
                end

                -- ================= UNIFIED TRASH NOTES (add-flow) =================
                if type(db.trashNotesList)    ~= "table" then db.trashNotesList    = {} end
                if type(db.trashNotesListMig) ~= "table" then db.trashNotesListMig = {} end

                local rk = currentRaid.key
                local scopedRkP = ProfileKeyForRaidShort(currentRaid)
                local profNow = scopedRkP:match("|(.+)$") or "Default"
                local list = RC.GetTrashNoteList and RC:GetTrashNoteList(rk, profNow)

                local function SaveAndRearm()
                    RC:SaveConfigurationToProfile()
                    if RC.RebuildTrashKillWatch then RC:RebuildTrashKillWatch() end
                end
                local function Rerender()
                    RC:ShowSidebarBossNotes(frame, "trash")
                end

                local function NumField(parentCard, x, y, initial, maxV, onSave)
                    local eb = RC.UI:CreateBackedEditBox(parentCard, {
                        width = 34, height = 20, numeric = true, maxLetters = 3,
                        justify = "CENTER", fontSize = 11,
                    })
                    eb:SetPoint("TOPLEFT", parentCard, "TOPLEFT", x, y)
                    eb:SetText(tostring(initial))
                    local function commit()
                        local n = tonumber(eb:GetText()) or initial
                        if n < 1 then n = 1 end
                        if n > maxV then n = maxV end
                        eb:SetText(tostring(n))
                        onSave(n)
                    end
                    eb:SetScript("OnEditFocusLost", commit)
                    eb:SetScript("OnEnterPressed", function(sf) sf:ClearFocus() end)
                    eb:SetScript("OnEscapePressed", function(sf) sf:ClearFocus() end)
                end

                local headCard = self:CreateSettingsCard(parent, yPos,
                    currentRaid.label .. RCL[" - trash notes"])
                local hy = -32
                hy = RC.UI:CreateHelpLine(headCard, 15, hy, RCL["Add a note, pick its trash mobs (whole packs or single mobs), write the "]
                    .. RCL["text, then choose the trigger: fire after X kills (shows for a set duration, once "]
                    .. RCL["per instance entry) or show while targeting one of the mobs. Kill detection shares "]
                    .. RCL["the addon's single scoped combat-log reader - active only while a kill-triggered "]
                    .. RCL["note exists, one check per kill, zero idle cost."],
                    { short = RCL["Pick trash mobs, write the note, then choose when it shows: after X kills or while targeting."],
                      title = RCL["Trash notes"], gap = 10 })

                if list then
                    local addBtn = self.UI:CreateStyledButton(headCard, RCL["Add trash note"], 130, 22)
                    addBtn:SetPoint("TOPLEFT", headCard, "TOPLEFT", 15, hy)
                    addBtn:SetScript("OnClick", function()
                        list[#list + 1] = { text = "", mobs = {}, kills = 1, dur = 8 }
                        RC:SaveConfigurationToProfile()
                        Rerender()
                    end)
                    hy = hy - 30
                else
                    local warn = self:CreateFontString(headCard, "OVERLAY", nil, 10)
                    warn:SetPoint("TOPLEFT", headCard, "TOPLEFT", 15, hy)
                    warn:SetText(RCL["Raid profiles are still loading - reopen this page in a moment."])
                    warn:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                    hy = hy - 20
                end
                headCard:SetContentHeight(math.abs(hy))
                yPos = yPos - headCard:GetHeight() - 15

                if list and #list == 0 then
                    local emptyCard = self:CreateSettingsCard(parent, yPos, RCL["No trash notes yet"])
                    local ey2 = -32
                    local eL = self:CreateFontString(emptyCard, "OVERLAY", nil, 10)
                    eL:SetPoint("TOPLEFT", emptyCard, "TOPLEFT", 15, ey2)
                    eL:SetText(RCL["Use 'Add trash note' above to create your first one."])
                    eL:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                    ey2 = ey2 - 22
                    emptyCard:SetContentHeight(math.abs(ey2))
                    yPos = yPos - emptyCard:GetHeight() - 15
                end

                for noteIdx, note in ipairs(list or {}) do
                    if type(note.mobs) ~= "table" then note.mobs = {} end
                    local card = self:CreateSettingsCard(parent, yPos, RCL["Trash note "] .. noteIdx)
                    local ny = -32
                    local cardW = card:GetWidth() - 30

                    local remX = RC.UI:CreateXCloseButton(card, 16, function()
                        table.remove(list, noteIdx)
                        SaveAndRearm()
                        Rerender()
                    end)
                    remX:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -8)

                    local inNote = {}
                    for _, m in ipairs(note.mobs) do inNote[m:lower()] = true end
                    local items = {}
                    local packs2 = RC.trashPacks and RC.trashPacks[rk]
                    if packs2 then
                        for _, pack in ipairs(packs2) do
                            items[#items + 1] = { text = RCL["Pack: "] .. (pack.label or pack.key),
                                                  value = "__pack:" .. pack.key }
                        end
                    end
                    local mobPool, seenMob = {}, {}
                    local raidLongForMobs = RAID_KEY_TO_NAME[rk]
                    local sections = raidLongForMobs and RC.raidData
                        and RC.raidData[raidLongForMobs]
                        and RC.raidData[raidLongForMobs].trashSections
                    if sections then
                        for _, mobsInWing in pairs(sections) do
                            for _, m in ipairs(mobsInWing) do
                                if not seenMob[m] then
                                    seenMob[m] = true
                                    mobPool[#mobPool + 1] = m
                                end
                            end
                        end
                        table.sort(mobPool)
                    else
                        for _, m in ipairs(currentRaid.mobs or {}) do
                            mobPool[#mobPool + 1] = m
                        end
                    end
                    for _, m in ipairs(mobPool) do
                        if not inNote[m:lower()] then
                            items[#items + 1] = { text = m, value = m }
                        end
                    end

                    local addLbl = self:CreateFontString(card, "OVERLAY", nil, 10)
                    addLbl:SetPoint("TOPLEFT", card, "TOPLEFT", 15, ny - 5)
                    addLbl:SetText(RCL["Add:"])
                    addLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
                    local addDD = self.UI:CreateScrollableDropdown(card, 220, RCL["Pick a mob or pack..."], 10)
                    addDD:SetEmptyText(RCL["Every mob is already in this note"], nil)
                    addDD:SetPoint("TOPLEFT", card, "TOPLEFT", 50, ny)
                    addDD:SetItems(items, function(value)
                        local pkey = value:match("^__pack:(.+)$")
                        if pkey and packs2 then
                            for _, pack in ipairs(packs2) do
                                if pack.key == pkey then
                                    for _, m in ipairs(pack.mobs or {}) do
                                        if not inNote[m:lower()] then
                                            note.mobs[#note.mobs + 1] = m
                                            inNote[m:lower()] = true
                                        end
                                    end
                                end
                            end
                        elseif not inNote[value:lower()] then
                            note.mobs[#note.mobs + 1] = value
                        end
                        SaveAndRearm()
                        Rerender()
                    end)
                    ny = ny - 32

                    if #note.mobs == 0 then
                        local noMob = self:CreateFontString(card, "OVERLAY", nil, 10)
                        noMob:SetPoint("TOPLEFT", card, "TOPLEFT", 15, ny)
                        noMob:SetText(RCL["No mobs yet - this note can't fire until you add some."])
                        noMob:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                        ny = ny - 18
                    else
                        local colW = math.floor(cardW / 2)
                        for mi, mob in ipairs(note.mobs) do
                            local col = (mi - 1) % 2
                            local rowY = ny - math.floor((mi - 1) / 2) * 20
                            local mx = RC.UI:CreateXCloseButton(card, 13, function()
                                table.remove(note.mobs, mi)
                                SaveAndRearm()
                                Rerender()
                            end)
                            mx:SetPoint("TOPLEFT", card, "TOPLEFT", 15 + col * colW, rowY - 2)
                            local mFS = self:CreateFontString(card, "OVERLAY", nil, 10)
                            mFS:SetPoint("TOPLEFT", card, "TOPLEFT", 15 + col * colW + 18, rowY - 4)
                            mFS:SetWidth(colW - 24)
                            mFS:SetJustifyH("LEFT")
                            mFS:SetWordWrap(false)
                            mFS:SetText(mob)
                            mFS:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
                        end
                        ny = ny - math.ceil(#note.mobs / 2) * 20 - 4
                    end

                    local trigLbl = self:CreateFontString(card, "OVERLAY", nil, 10)
                    trigLbl:SetPoint("TOPLEFT", card, "TOPLEFT", 15, ny - 5)
                    trigLbl:SetText(RCL["Trigger:"])
                    trigLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
                    local curTrig = (note.trigger == "target") and "target" or "kills"
                    local trigDD = self.UI:CreateScrollableDropdown(card, 170,
                        (curTrig == "target") and RCL["While targeting"] or RCL["After X kills"], 4)
                    trigDD:SetPoint("TOPLEFT", card, "TOPLEFT", 75, ny)
                    trigDD:SetItems({
                        { text = RCL["After X kills"],   value = "kills"  },
                        { text = RCL["While targeting"], value = "target" },
                    }, function(value)
                        note.trigger = (value == "target") and "target" or nil
                        SaveAndRearm()
                        Rerender()
                    end)
                    ny = ny - 32

                    local wrapperKey = "__tnote:" .. noteIdx
                    local wrapper = { notes = { [wrapperKey] = note.text or "" } }
                    local con = CreateNoteEditBox(card, wrapper, wrapperKey, 0, 60)
                    con:SetPoint("TOPLEFT",  card, "TOPLEFT",  15, ny)
                    con:SetPoint("TOPRIGHT", card, "TOPRIGHT", -15, ny)
                    local eb = con.editBox
                    local function commitText()
                        note.text = eb:GetText() or ""
                        SaveAndRearm()
                    end
                    eb:SetScript("OnEditFocusLost", commitText)
                    eb:SetScript("OnEscapePressed", function(sf) sf:ClearFocus(); commitText() end)
                    ny = ny - 68

                    ny = BuildPerNoteToolbar(card, ny, eb)

                    if curTrig == "target" then
                        local tl = self:CreateFontString(card, "OVERLAY", nil, 10)
                        tl:SetPoint("TOPLEFT", card, "TOPLEFT", 15, ny - 3)
                        tl:SetText(RCL["Shows while any of this note's mobs is your target."])
                        tl:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                        ny = ny - 26
                        card:SetContentHeight(math.abs(ny))
                        yPos = yPos - card:GetHeight() - 15
                    else

                    local l1 = self:CreateFontString(card, "OVERLAY", nil, 10)
                    l1:SetPoint("TOPLEFT", card, "TOPLEFT", 15, ny - 3)
                    l1:SetText(RCL["Fires after"])
                    l1:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                    NumField(card, 75, ny, tonumber(note.kills) or 1, 999, function(n)
                        note.kills = n; SaveAndRearm()
                    end)
                    local l2 = self:CreateFontString(card, "OVERLAY", nil, 10)
                    l2:SetPoint("TOPLEFT", card, "TOPLEFT", 114, ny - 3)
                    l2:SetText(RCL["kills  -  shows for"])
                    l2:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                    NumField(card, 212, ny, tonumber(note.dur) or 8, 120, function(n)
                        note.dur = n; SaveAndRearm()
                    end)
                    local l3 = self:CreateFontString(card, "OVERLAY", nil, 10)
                    l3:SetPoint("TOPLEFT", card, "TOPLEFT", 251, ny - 3)
                    l3:SetText(RCL["seconds"])
                    l3:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                    ny = ny - 30

                    card:SetContentHeight(math.abs(ny))
                    yPos = yPos - card:GetHeight() - 15
                    end
                end
            end
        end
        -- the note frame's layer / fade / shadow (the customization standard)
        yPos = self.UI:FrameCardsForTab(selectedTab, parent, yPos, function() return RC.db.bossNotes end,
            function() if RC.ApplyBossNotesPosition then RC:ApplyBossNotesPosition() end end,
            { chromeFields = { shadowSize = true, shadowColor = true, glowSize = true, glowColor = true } })

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
        if isTabSwitch then self:RestoreScrollPosition(self.sidebarConfigFrame) end
    end

    RC:DebugPrint("ConfigUI_Consumables panels loaded", "system")
