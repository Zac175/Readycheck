------------------------------------------------------------------------
-- Readycheck - Equipment: Base / On-Use Item Revert
-- Hosts shared helpers (preview art, palette, colors) in RC._seq for the
-- other Equipment pages (Equip_GMConfig, Equip_SetEditor, Equip_Trinket-
-- Queues), and owns the On-Use Gear Swaps ("speed swap") panel.
-- Edits db.gearUseRevert, db.speedSwapTargets, db.itemEnchantPreference;
-- pokes RC:SaveConfigurationToProfile on change.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_max, math_min = math.floor, math.max, math.min
local table_insert, table_sort = table.insert, table.sort
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetItemInfo = GetItemInfo or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemInfo)
local RC = _G.Readycheck
if not (RC and RC.UI) then return end
RC._seq = RC._seq or {}
local _seq = RC._seq

    local function GetGearSetPreviewPath(setName)
        if not setName then return nil end
        local base = "Interface\\AddOns\\Readycheck\\Media\\GearPreviews\\"
        if setName == "Battle Shout" then
            return base .. "battleshout.tga"
        elseif setName == "Diamond Flask" then
            return base .. "diamondflask.tga"
        end
        if setName == "DPS" then
            return base .. "normgear.tga"
        end
        return nil
    end
    RC.GetGearSetPreviewPath = function(_, name) return GetGearSetPreviewPath(name) end

    local function GetTabHoverBg()
        return RC:GetColor("sidebar", "buttonHover")
    end

    local function GetCardBg()
        return RC:GetColor("ui", "cardBackground")
    end

    local TEXT = RC.UI and RC.UI.TEXT or {}

    local C = {
        black    = {0,    0,    0,    1   },
        blackDim = {0,    0,    0,    0.8 },
        blackHalf= {0,    0,    0,    0.5 },
        cardBg   = {0.08, 0.08, 0.08, 1   },
        yellow   = {1,    1,    0,    1   },
    }

    function RC:ShowSidebarSpeedSwaps(frame)
        self:ClearSidebarContent(self.sidebarConfigFrame)
        local parent = frame.scrollChild
        local yPos = -20
        local _, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["On-Use Gear Swaps"],
            RCL["On-use gear swaps back after its buff ends"], "Interface\\Icons\\INV_Boots_02")
        yPos = newY

        local TG = self.UI and self.UI.TEXT and self.UI.TEXT.gray or { 0.5, 0.5, 0.5 }

        local enCard = self:CreateSettingsCard(parent, yPos, RCL["Enable"])
        local cb = self.UI:CreateCheckbox(enCard, RCL["Swap back after use"],
            self.db.gearUseRevert ~= false)
        cb:SetPoint("TOPLEFT", enCard, "TOPLEFT", 14, -35)
        cb:SetScript("OnClick", function()
            self.db.gearUseRevert = cb:GetChecked() and true or false
            self:ForceCheckboxUpdate(cb, self.db.gearUseRevert)
            -- Without this the watcher stays deaf until the next gear
            -- change when the tracked item is already worn.
            if RC.UpdateGearUseRevertReg then RC.UpdateGearUseRevertReg() end
            self:SaveConfigurationToProfile()
        end)
        local capY = RC.UI:CreateHelpLine(enCard, 14, -60, RCL["When one of these items is used, the slot returns to your pick below - or to whatever was worn before, if nothing is picked. In combat the swap waits for the combat edge. Trinkets on rotation belong to Trinket Auto-Swap, not this."],
            { short = RCL["After one of these items is used, its slot goes back to your pick below (or what was worn before)."], title = RCL["Swap back"] })
        enCard:SetContentHeight(math.abs(capY))
        yPos = yPos - enCard:GetHeight() - 10

        local function EnchantLabel(link, eid, bag, bagSlot)
            -- Enchant id 911 has no matching tooltip line to scan for, so
            -- it is special-cased directly instead of falling through.
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
        local function CopyVariants(itemId)
            local out = { { text = RCL["Any copy"], value = 0 } }
            local seenE = {}
            for bag = 0, 4 do
                local n = C_Container.GetContainerNumSlots(bag) or 0
                for sl = 1, n do
                    if C_Container.GetContainerItemID(bag, sl) == itemId then
                        local lk = C_Container.GetContainerItemLink(bag, sl)
                        local eid = lk and tonumber(lk:match("item:%d+:(%d*)") or "")
                        if eid and eid > 0 and not seenE[eid] then
                            seenE[eid] = true
                            out[#out + 1] = { text = EnchantLabel(lk, eid, bag, sl),
                                value = eid }
                        end
                    end
                end
            end
            return out
        end

        local function Candidates(trackedId)
            local out = { { text = RCL["Previous item (default)"], value = 0 } }
            local seen = { [trackedId] = true }
            local loc = select(4, GetItemInfoInstant(trackedId))
            -- Shield / holdable / offhand-weapon / one-hand-weapon all
            -- share the offhand slot, so their candidate pools merge.
            local GROUPS = {
                INVTYPE_HOLDABLE      = { INVTYPE_HOLDABLE = true, INVTYPE_SHIELD = true,
                                          INVTYPE_WEAPONOFFHAND = true, INVTYPE_WEAPON = true },
                INVTYPE_SHIELD        = { INVTYPE_HOLDABLE = true, INVTYPE_SHIELD = true,
                                          INVTYPE_WEAPONOFFHAND = true, INVTYPE_WEAPON = true },
                INVTYPE_WEAPONOFFHAND = { INVTYPE_HOLDABLE = true, INVTYPE_SHIELD = true,
                                          INVTYPE_WEAPONOFFHAND = true, INVTYPE_WEAPON = true },
            }
            local ok = GROUPS[loc]
            local function push(id)
                if not id or id == 0 or seen[id] then return end
                local iloc = select(4, GetItemInfoInstant(id))
                if ok then
                    if not ok[iloc] then return end
                elseif iloc ~= loc then return end
                seen[id] = true
                local nm = GetItemInfo(id) or ("Item " .. id)
                out[#out + 1] = { text = nm, value = id, icon = GetItemIcon(id) }
            end
            for slot = 1, 19 do push(GetInventoryItemID("player", slot)) end
            for bag = 0, 4 do
                local n = C_Container.GetContainerNumSlots(bag) or 0
                for sl = 1, n do push(C_Container.GetContainerItemID(bag, sl)) end
            end
            return out
        end

        local itCard = self:CreateSettingsCard(parent, yPos, RCL["Items"])
        local cy = -32
        self.db.speedSwapTargets = self.db.speedSwapTargets or {}
        for _, entry in ipairs(self.speedSwapItems or {}) do
            local ic = itCard:CreateTexture(nil, "ARTWORK")
            ic:SetSize(18, 18)
            ic:SetPoint("TOPLEFT", itCard, "TOPLEFT", 14, cy)
            ic:SetTexture(GetItemIcon and GetItemIcon(entry.id)
                or "Interface\\Icons\\INV_Misc_QuestionMark")
            local nf = self:CreateFontString(itCard, "OVERLAY", nil, 11)
            nf:SetPoint("TOPLEFT", itCard, "TOPLEFT", 39, cy - 3)
            nf:SetWidth(150)
            nf:SetJustifyH("LEFT")
            nf:SetWordWrap(false)
            local wornNow = false
            for ws = 1, 19 do
                if GetInventoryItemID("player", ws) == entry.id then
                    wornNow = true
                    break
                end
            end
            nf:SetText(entry.name .. (wornNow and " |cFF77FF77(worn)|r" or ""))
            -- a long name is cut short in its column: hovering shows it whole
            local nfHit = CreateFrame("Frame", nil, itCard)
            nfHit:SetAllPoints(nf)
            nfHit:EnableMouse(true)
            self.UI:TruncTip(nf, nfHit)
            local cur = self.db.speedSwapTargets[entry.id]
            local curTxt = "Previous item (default)"
            if cur and cur ~= 0 then
                curTxt = GetItemInfo(cur) or ("Item " .. cur)
            end
            local dd = self.UI:CreateScrollableDropdown(itCard, 200, curTxt, 8)
            dd:SetPoint("TOPLEFT", itCard, "TOPLEFT", 196, cy + 2)
            dd:SetItems(Candidates(entry.id), function(value)
                if value == 0 then
                    self.db.speedSwapTargets[entry.id] = nil
                else
                    self.db.speedSwapTargets[entry.id] = value
                end
                self:SaveConfigurationToProfile()
            end)
            local variants = CopyVariants(entry.id)
            if #variants > 1 then
                self.db.itemEnchantPreference = self.db.itemEnchantPreference or {}
                local curE = self.db.itemEnchantPreference[entry.id]
                local curELbl = "Any copy"
                for _, v in ipairs(variants) do
                    if v.value == curE then curELbl = v.text end
                end
                local edd = self.UI:CreateScrollableDropdown(itCard, 170, curELbl, 6)
                edd:SetPoint("TOPLEFT", itCard, "TOPLEFT", 404, cy + 2)
                edd:SetItems(variants, function(value)
                    self.db.itemEnchantPreference = self.db.itemEnchantPreference or {}
                    if value == 0 then
                        self.db.itemEnchantPreference[entry.id] = nil
                    else
                        self.db.itemEnchantPreference[entry.id] = value
                    end
                    self:SaveConfigurationToProfile()
                end)
            end
            cy = cy - 30
        end
        itCard:SetContentHeight(math.abs(cy) + 6)
        yPos = yPos - itCard:GetHeight() - 10

        self:UpdateSidebarScrollbar(frame)
    end

    ------------------------------------------------------------------
    -- Setting rows shared by the gear pages (Gear Manager, Trinket
    -- Manager, Equipment Reminder, Repair Reminder): one look, every
    -- control a framework widget, so each one reaches the preview pane on
    -- its own. Each returns the next y inside the card (x = 14).
    ------------------------------------------------------------------
    local L = {}

    local function Col(cat, key)
        local c = RC:GetColor(cat, key)
        return c.r or 1, c.g or 1, c.b or 1
    end

    -- a table under `root` that may still be nil in an old profile
    function L.Sub(root, key)
        if type(root[key]) ~= "table" then root[key] = {} end
        return root[key]
    end

    local function SaveSoon(widget)
        if widget.saveTimer then widget.saveTimer:Cancel() end
        widget.saveTimer = C_Timer.NewTimer(0.4, function() RC:SaveConfigurationToProfile() end)
    end
    L.SaveSoon = SaveSoon

    -- gray 10px note under a control, one line at most (the rest in its
    -- tooltip: RC.UI:CreateHelpLine)
    function L.Desc(card, y, text, x)
        local ny, h = RC.UI:CreateHelpLine(card, x or 14, y, text, { gap = 6 })
        return ny, h.text
    end

    function L.Label(card, y, text, x)
        local fs = RC:CreateFontString(card, "OVERLAY", nil, 11)
        fs:SetPoint("TOPLEFT", card, "TOPLEFT", x or 14, y)
        fs:SetText(text)
        fs:SetTextColor(Col("text", "normal"))
        return y - 20, fs
    end

    -- onChange(on) after the box is ticked; desc optional
    function L.Check(card, y, label, checked, onChange, desc)
        local cb = RC.UI:CreateSettingCheckbox(card, y, label, checked and true or false, function(b)
            local on = b:GetChecked() and true or false
            RC:ForceCheckboxUpdate(b, on)
            onChange(on, b)
        end)
        cb._rcLabel = label
        y = y - 24
        if desc then y = L.Desc(card, y + 2, desc, 38) - 2 end
        return y, cb
    end

    -- o = { label, min, max, step, value, set = fn(v), fmt = fn(v) -> text,
    --       scale = k (slider runs on v * k: fractions), width }
    function L.Slider(card, y, o)
        if o.label then y = L.Label(card, y, o.label) end
        local k = o.scale or 1
        local step = (o.step or 1) * k
        local function Fmt(v) return o.fmt and o.fmt(v) or tostring(v) end
        local v0 = tonumber(o.value) or o.min
        local s = RC.UI:CreateSlider(card, o.min * k, o.max * k, v0 * k, step)
        s:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
        if o.width then s:SetWidth(o.width) end
        s.Text:SetText(Fmt(v0))
        s:SetScript("OnValueChanged", function(sl, raw)
            local v = math_floor(raw / step + 0.5) * step / k
            sl.Text:SetText(Fmt(v))
            if sl.syncing then return end
            o.set(v)
            SaveSoon(sl)
        end)
        s._rcLabel = o.label
        return y - 44, s
    end

    -- A theme colour (Appearance > Colors entry) edited in place.
    function L.ThemeColor(card, y, cat, key, label, tooltip, onChange)
        local cp = RC.UI:CreateColorPicker(card, { label = label, width = 420, tooltip = tooltip,
            get = function() return RC:GetColor(cat, key) end,
            set = function(r, g, b) RC:SetColor(cat, key, r, g, b, (RC:GetColor(cat, key).a or 1)) if onChange then onChange() end end,
            isChanged = function()
                local cc = RC.db and RC.db.customColors
                return (cc and cc[cat] and cc[cat][key]) ~= nil
            end,
            reset = function() RC:ResetColor(cat, key) if onChange then onChange() end end,
        })
        cp:SetPoint("TOPLEFT", card, "TOPLEFT", 10, y)
        cp._rcLabel = label
        return y - 28, cp
    end

    -- A feature's own colour: nil = fallback() (a theme colour).
    function L.OwnColor(card, y, tbl, key, label, fallback, onChange, tooltip, alpha)
        local cp = RC.UI:CreateColorPicker(card, { label = label, width = 420, tooltip = tooltip, alpha = alpha,
            get = function() return tbl[key] or fallback() end,
            set = function(r, g, b, a) tbl[key] = { r = r, g = g, b = b, a = a or 1 } if onChange then onChange() end RC:SaveConfigurationToProfile() end,
            isChanged = function() return type(tbl[key]) == "table" end,
            reset = function() tbl[key] = nil if onChange then onChange() end RC:SaveConfigurationToProfile() end,
        })
        cp:SetPoint("TOPLEFT", card, "TOPLEFT", 10, y)
        cp._rcLabel = label
        return y - 28, cp
    end

    function L.Font(card, y, tbl, key, label, defaults, sample, onChange)
        local fp = RC.UI:CreateFontPicker(card, { label = label, width = 420,
            get = function() return tbl[key] end,
            set = function(spec) tbl[key] = spec if onChange then onChange() end RC:SaveConfigurationToProfile() end,
            defaults = defaults, minSize = 6, maxSize = 40, sample = sample })
        fp:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
        fp._rcLabel = label
        return y - fp:GetHeight() - 10, fp
    end

    -- how: "in" (appears), "out" (goes), "update" (attention)
    function L.Anim(card, y, tbl, key, label, how, defaults, P, styles, onChange)
        local ap = RC.UI:CreateAnimationPicker(card, { label = label, width = 460, how = how,
            get = function() return tbl[key] end,
            set = function(spec)
                tbl[key] = spec
                if onChange then onChange() end
                RC:SaveConfigurationToProfile()
                if P then P.Replay() end
            end,
            defaults = defaults, styles = styles })
        ap:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
        ap._rcLabel = label
        return y - ap:GetHeight() - 10, ap
    end

    -- A card, filled by fn(card, y) -> y; returns the page y below it.
    function L.Card(parent, yPos, title, fn)
        local card = RC:CreateSettingsCard(parent, yPos, title)
        local cy = fn(card, -32)
        card:SetContentHeight(math.abs(cy) + 4)
        return yPos - card:GetHeight() - 15, card
    end

    -- Old tab keys (search aliases, saved per session) -> standard ones.
    function L.TabKey(key, valid, map, fallback)
        key = (map and map[key]) or key
        for _, t in ipairs(valid) do
            if (t.key or t[1]) == key then return key end
        end
        return fallback
    end

    _seq.Look = L

    _seq.GetGearSetPreviewPath = GetGearSetPreviewPath
    _seq.GetTabHoverBg = GetTabHoverBg
    _seq.GetCardBg = GetCardBg
    _seq.TEXT = TEXT
    _seq.C = C
