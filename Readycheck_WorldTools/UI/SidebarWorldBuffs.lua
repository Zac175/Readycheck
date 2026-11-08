------------------------------------------------------------------------
-- Readycheck - World Buffs
-- Sidebar page for the World Buff board (Songflower, DMF, Rallying Cry,
-- Warchief's Blessing, etc) and the standalone mini board popup (/wb).
-- Settings live under RC.db.worldBuffs (hideBelowMax, miniFilter,
-- miniOnlineOnly, miniPos, miniW/miniH, boardSort, boardSortTopClass);
-- roster/buff data itself comes from RC.WorldBuffs (mesh-synced), not
-- from RC.db.
------------------------------------------------------------------------
-- World buffs are Classic Era content: TBC and Forever never run this
-- addon (Readycheck Core_Flavor).
if _G.Readycheck and _G.Readycheck.FeatureOn and not _G.Readycheck:FeatureOn("world_tools") then return end

-- Taint-safe API locals (fallbacks on RC.Compat, built in Core;
-- never write _G - a written Blizzard global taints its readers)
local RCC = _G.Readycheck
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)
local GetSpellInfo = GetSpellInfo or (RCC and RCC.Compat and RCC.Compat.GetSpellInfo)

local function InitializeSidebarWorldBuffs()
    local RC = _G.Readycheck
    if not RC then C_Timer.After(0.1, InitializeSidebarWorldBuffs) return end
    if not RC.CreateSettingsCard then C_Timer.After(0.2, InitializeSidebarWorldBuffs) return end

    local ICON     = 24
    local NAMEW    = 110
    local ICON_X0  = NAMEW + 8
    local ICON_GAP = 30
    local ROWH     = 52

    local CHRONO_ICON = (GetItemIcon and GetItemIcon(184937)) or "Interface\\Icons\\Spell_Nature_TimeStop"
    local HS_ICON     = (GetItemIcon and GetItemIcon(6948))   or "Interface\\Icons\\INV_Misc_Rune_01"
    local DMF_ICON    = select(3, GetSpellInfo(23735)) or "Interface\\Icons\\INV_Misc_Ticket_Tarot_Stack_01"
    local DMF_CD_TIP  = "Sayge lockout"

    local DMF_CITIES = { "Orgrimmar", "Thunder Bluff", "Undercity",
        "Stormwind", "Ironforge", "Darnassus" }
    -- Projects the Sayge/DMF lockout as cleared once 8h have passed since the
    -- last known fortune and the toon's last reported location was a home city
    -- (implies a reset happened); purely a display heuristic, not a real timer.
    local function DmfShow(p)
        local rem = p and p.dmfRem
        if not rem or rem <= 0 then return rem end
        if p.online then return rem end
        local last = p.t or p.goldT or 0
        if last > 0 and (time() - last) >= 8 * 3600 then
            local loc = tostring(p.location or "")
            for _, city in ipairs(DMF_CITIES) do
                if loc:find(city, 1, true) then return 0 end
            end
        end
        return rem
    end

    local function FmtTime(secs)
        if not secs or secs <= 0 then return "" end
        if secs >= 60 then return math.floor(secs / 60 + 0.5) .. "m" end
        return math.floor(secs) .. "s"
    end

    -- worldBuffs.formats.time / .cd: a buff cell's / a cooldown cell's
    -- timer. Nothing saved = FmtTime (58m / 45s); a format words it from
    -- the seconds (defaults { time = "short" }, which reads the same).
    RC.WB_TIME_FORMAT = { time = "short" }
    local wbFmtVals, wbFmtKinds = {}, { value = "time" }
    local function TimerText(secs, key)
        local w = RC.db and RC.db.worldBuffs
        local f = w and w.formats
        local spec = type(f) == "table" and f[key] or nil
        if not spec then return FmtTime(secs) end
        if not secs or secs <= 0 then return "" end
        wbFmtVals.value = secs
        return RC.UI:FormatText(spec, RC.WB_TIME_FORMAT, wbFmtVals, wbFmtKinds, "value")
    end
    RC._wbTimerText = TimerText

    -- worldBuffs.anchors.*: a spec moves a board text from where the board
    -- puts it (call right after the board's own SetPoint, same values); no
    -- spec = untouched, a cleared one puts the point and justify back.
    --   name / sub     a toon's name and where it is (targets: the row, the other)
    --   time           a buff cell's timer (the cell's icon, the row)
    --   cd / count     a cooldown cell's timer and Chronoboon count
    local function WBAnchors()
        local w = RC.db and RC.db.worldBuffs
        local a = w and w.anchors
        return type(a) == "table" and a or nil
    end
    local function PlaceText(fs, key, point, to, relPoint, x, y, resolveTo)
        local a = WBAnchors()
        local sp = a and a[key] or nil
        if not sp and not fs._wbMoved then return end
        -- (the justify the board gave it, kept from the first move)
        if not fs._wbMoved then fs._wbJH = fs:GetJustifyH() end
        fs:ClearAllPoints()
        fs:SetPoint(point, to, relPoint, x, y)
        if fs._wbJH then fs:SetJustifyH(fs._wbJH) end
        if sp then
            fs._wbDef = fs._wbDef or {}
            RC.UI:AnchorOver(fs, sp, fs._wbDef, point, to, relPoint, x, y, resolveTo)
        end
        fs._wbMoved = sp ~= nil
    end
    local function RowTo(row)
        local fn = row._wbTo
        if not fn then
            fn = function(k)
                if k == "row" then return row elseif k == "name" then return row.nameFs elseif k == "sub" then return row.subFs end
                return nil
            end
            row._wbTo = fn
        end
        return fn
    end
    local function CellTo(row, cell)
        local fn = cell.to
        if not fn then
            fn = function(k)
                if k == "icon" then return cell.icon elseif k == "row" then return row
                elseif k == "time" or k == "cd" then return cell.txt elseif k == "count" then return cell.countFs end
                return nil
            end
            cell.to = fn
        end
        return fn
    end

    local function ClassColor(classFile)
        if classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
            return RAID_CLASS_COLORS[classFile]
        end
        return nil
    end

    local function StripRealm(name)
        if not name then return "?" end
        local s = name:match("^[^-]+") or name
        return (s:gsub("^%l", string.upper))
    end

    local function SublineFor(info)
        if not info.online then
            local loc = info.location
            if info.pvp then
                return (loc and loc ~= "" and ("PvP - " .. loc)) or "PvP", RC:GetColor("text", "red")
            end
            if loc and loc ~= "" then
                return loc, RC:GetColor("text", "gray")
            end
            return "offline", RC:GetColor("text", "gray")
        end
        local loc = info.location
        -- A booned toon has its buffs stored, not missing.
        if (info.count or 0) == 0 and not info.booned then
            if info.pvp then return "needs buffs - PvP", RC:GetColor("text", "red") end
            return "needs buffs", RC:GetColor("text", "red")
        end
        if info.pvp then
            return (loc and loc ~= "" and ("PvP - " .. loc)) or "PvP", RC:GetColor("text", "red")
        end
        if loc and loc ~= "" then
            return loc, RC:GetColor("text", "gray")
        end
        if info.isLocal then
            return "you", RC:GetColor("text", "gray")
        end
        return (info.label or ""), RC:GetColor("text", "gray")
    end

    -- Re-applies a pooled font string's size. RC:CreateFontString records the
    -- size it was built at, so a row that is reused across a resize can be
    -- rescaled without being thrown away and rebuilt.
    local function ResizeFont(fs, size)
        if not fs or fs._wrFontSize == size then return end
        fs._wrFontSize = size
        if RC.ApplyCustomFont then
            RC:ApplyCustomFont(fs, size, fs._wrFontOutline)
        end
        if not fs:GetFont() then
            fs:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size, fs._wrFontOutline)
        end
    end

    -- THE BOARD'S LOOK (worldBuffs.look; every nil field is the original
    -- look): the state colours, the three fonts, the compact board's cell
    -- size and row height, its stripes. RC._wbLookSig moves on with every
    -- change so pooled strings restyle once, not on every refresh.
    local function WBLook()
        local w = RC.db and RC.db.worldBuffs
        local l = w and w.look
        return type(l) == "table" and l or {}
    end
    RC._wbLook = WBLook
    RC._wbLookSig = RC._wbLookSig or 0

    local function StateColor(state)
        local l = WBLook()
        if state == "active" then return l.activeColor or RC:GetColor("text", "yellow") end
        if state == "booned" then return l.boonedColor or RC:GetColor("text", "green") end
        return l.missingColor or RC:GetColor("text", "red")
    end
    RC._wbStateColor = StateColor

    local function StyleFont(fs, spec, size)
        local sig = RC._wbLookSig .. ":" .. size
        if fs._wbSig == sig then return end
        fs._wbSig = sig
        fs._wrFontSize = size
        RC:ApplyFontSpec(fs, spec, { size = size, outline = fs._wrFontOutline or "OUTLINE" })
    end

    -- One hit frame per row, kept on the row so a pooled row reuses it. The
    -- peer it describes lives on the frame (self.info) rather than in an
    -- upvalue, because the frame outlives the call that last filled it.
    local function AttachNameTooltip(row, info, width, height)
        local hit = row.nameHit
        if not hit then
            hit = CreateFrame("Frame", nil, row)
            hit:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
            hit:EnableMouse(true)
            hit:SetScript("OnEnter", function(self)
                local peer = self.info
                if not peer then return end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                local nc = ClassColor(peer.class) or RC:GetColor("ui", "headerText")
                GameTooltip:AddLine(StripRealm(peer.name), nc.r, nc.g, nc.b)
                local gray = RC:GetColor("text", "gray")
                if peer.online then
                    local loc = peer.location
                    if loc and loc ~= "" then
                        GameTooltip:AddLine(RCL["Location: "] .. loc, gray.r, gray.g, gray.b)
                    else
                        GameTooltip:AddLine(RCL["Location: unknown"], gray.r, gray.g, gray.b)
                    end
                    if peer.pvp then
                        local rc = RC:GetColor("text", "red")
                        GameTooltip:AddLine(RCL["PvP: flagged"], rc.r, rc.g, rc.b)
                    else
                        local gc = RC:GetColor("text", "green")
                        GameTooltip:AddLine(RCL["PvP: not flagged"], gc.r, gc.g, gc.b)
                    end
                else
                    local loc = peer.location
                    if loc and loc ~= "" then
                        GameTooltip:AddLine(RCL["Last seen: "] .. loc, gray.r, gray.g, gray.b)
                        if peer.pvp then
                            local rc = RC:GetColor("text", "red")
                            GameTooltip:AddLine(RCL["PvP: flagged (last known)"], rc.r, rc.g, rc.b)
                        else
                            local gc = RC:GetColor("text", "green")
                            GameTooltip:AddLine(RCL["PvP: not flagged (last known)"], gc.r, gc.g, gc.b)
                        end
                    else
                        GameTooltip:AddLine(RCL["Offline - location unknown"], gray.r, gray.g, gray.b)
                    end
                end
                GameTooltip:Show()
            end)
            hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
            row.nameHit = hit
        end
        hit:SetSize(width, height)
        hit.info = info
        return hit
    end

    -- RC._wbBoardDefs is a shared cache: ShowSidebarWorldBuffs() recomputes it
    -- (including active festival buffs) each render; the mini board reads the
    -- same cache and only falls back to non-festival buffs if it hasn't run yet.
    local function BoardDefs()
        if RC._wbBoardDefs then return RC._wbBoardDefs end
        local out = {}
        local WBm = RC.WorldBuffs
        for _, d in ipairs((WBm and WBm.BUFFS) or {}) do
            if not d.festival then out[#out + 1] = d end
        end
        return out
    end

    local function FilterPass(info, mode, onlineOnly)
        -- The character the board is open on is always listed: it is the
        -- row every other row is read against, whatever is filtered.
        if info.isLocal then return true end
        if onlineOnly and not info.online then return false end
        local hideLow = RC.db.worldBuffs and RC.db.worldBuffs.hideBelowMax
        if hideLow == nil then hideLow = true end
        if hideLow and not info.isLocal then
            if info.level then
                if info.level < 60 then return false end
            elseif not info.online then
                return false
            end
        end
        if mode == "needs" then return (info.count or 0) == 0 and not info.booned end
        if mode == "booned" then return info.booned and true or false end
        return true
    end
    local FILTER_LABELS = { all = "All", needs = "Needs buffs", booned = "Booned" }

    -- Board order. Both boards read the same two settings, so sorting one
    -- sorts the other.
    --
    --   db.worldBuffs.boardSort          the sort keys, most important
    --       first, as text: "class,-level,buffs" is by class, then lowest
    --       level first, then fewest buffs. A "-" reverses that key.
    --   db.worldBuffs.boardSortTopClass  a class token ("WARRIOR") whose
    --       rows are listed first, or "" for none.
    --
    -- Every key has a natural direction - fewest buffs, A to Z, highest
    -- level, online first. A row with nothing in a column (class, level
    -- or zone not known yet) goes below the rows that have it, whichever
    -- way that column is sorted. Rows equal on every key fall back to the
    -- name. None of this ever applies to your own row: the character the
    -- board is open on is the first row, always.
    local SORT_HINT = RCL["Click to sort by this alone. Shift-click to add it after the current sort, or to take it out again. Right-click to reverse it."]
    local SORT_ITEMS = {
        { key = "buffs",    label = RCL["Buffs"],  tooltip = RCL["Fewest buffs first, so whoever still needs some is on top."] },
        { key = "name",     label = RCL["Name"],   tooltip = RCL["Alphabetical by character name."] },
        { key = "class",    label = RCL["Class"],  tooltip = RCL["Grouped by class."] },
        { key = "level",    label = RCL["Level"],  tooltip = RCL["Highest level first."] },
        { key = "location", label = RCL["Zone"],   tooltip = RCL["Grouped by where each toon is."] },
        { key = "online",   label = RCL["Online"], tooltip = RCL["Online toons first."] },
    }
    local SORT_VALID = {}
    for _, item in ipairs(SORT_ITEMS) do
        SORT_VALID[item.key] = true
        item.tooltip = item.tooltip .. " " .. SORT_HINT
    end

    -- The classes a toon on these realms can be.
    local BOARD_CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
    local BOARD_CLASS_VALID = {}
    for _, token in ipairs(BOARD_CLASSES) do BOARD_CLASS_VALID[token] = true end
    local function ClassLabel(token)
        local shown = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]
        return shown or (token:sub(1, 1) .. token:sub(2):lower())
    end

    -- The saved order as a list of { key =, reversed = }. Read on every
    -- refresh, so the parse is kept until the text changes. Never empty,
    -- and never handed out to be edited: callers copy it.
    local sortOrderText, sortOrderList
    local function SortOrder()
        local wb = RC.db.worldBuffs
        -- The retired one-for-the-whole-board Reverse flag. The login
        -- cleanup folds it into boardSort, but it can also arrive later -
        -- settings synced or imported from a toon on an older version -
        -- so it is folded here as well, wherever it turns up.
        if wb and wb.boardSortReverse ~= nil then
            if wb.boardSortReverse == true and type(wb.boardSort) == "string"
               and wb.boardSort:find("^%a+$") then
                wb.boardSort = "-" .. wb.boardSort
            end
            wb.boardSortReverse = nil
        end
        local text = wb and wb.boardSort
        if type(text) ~= "string" then text = "buffs" end
        if text == sortOrderText then return sortOrderList end
        local out, seen = {}, {}
        for part in text:gmatch("[^,]+") do
            local minus, key = part:match("^%s*(%-?)(%a+)%s*$")
            if key and SORT_VALID[key] and not seen[key] then
                seen[key] = true
                out[#out + 1] = { key = key, reversed = (minus == "-") }
            end
        end
        if #out == 0 then out[1] = { key = "buffs", reversed = false } end
        sortOrderText, sortOrderList = text, out
        return out
    end

    local function SortOrderText(order)
        local parts = {}
        for i, entry in ipairs(order) do
            parts[i] = (entry.reversed and "-" or "") .. entry.key
        end
        return table.concat(parts, ",")
    end

    local function TopClass()
        local token = RC.db.worldBuffs and RC.db.worldBuffs.boardSortTopClass
        return BOARD_CLASS_VALID[token] and token or nil
    end

    local function SortKeyFor(key, info, name)
        if key == "name" then
            return name
        elseif key == "class" then
            local class = info.class
            if class and class ~= "" then
                return string.lower((LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class)
            end
            return nil
        elseif key == "level" then
            -- a level that is not a real number (it comes off the wire)
            -- counts as not known: comparing against it has no order
            local level = tonumber(info.level)
            if level and level == level and level > 0 and level < 1000 then return -level end
            return nil
        elseif key == "location" then
            local loc = info.location
            if loc and loc ~= "" then return string.lower(loc) end
            return nil
        elseif key == "online" then
            return info.online and 0 or 1
        end
        return info.count or 0
    end

    local function SortRoster(list)
        local order, top = SortOrder(), TopClass()
        local depth = #order
        for _, info in ipairs(list) do
            local name = string.lower(StripRealm(info.name))
            local keys = {}
            for i = 1, depth do keys[i] = SortKeyFor(order[i].key, info, name) end
            info._sortName, info._sortKeys = name, keys
            info._sortTop = (top and info.class == top) and 0 or 1
        end
        table.sort(list, function(a, b)
            if (a.isLocal and true or false) ~= (b.isLocal and true or false) then
                return a.isLocal and true or false
            end
            if a._sortTop ~= b._sortTop then return a._sortTop < b._sortTop end
            for i = 1, depth do
                local ka, kb = a._sortKeys[i], b._sortKeys[i]
                if ka ~= kb then
                    if ka == nil then return false end
                    if kb == nil then return true end
                    if order[i].reversed then return ka > kb end
                    return ka < kb
                end
            end
            if a._sortName ~= b._sortName then return a._sortName < b._sortName end
            return (a.name or "") < (b.name or "")
        end)
        return list
    end

    local function SaveSort(key, value)
        if not RC.db.worldBuffs then RC.db.worldBuffs = {} end
        RC.db.worldBuffs[key] = value
        RC:SaveConfigurationToProfile()
    end

    -- Fills `host` (a one-row frame) with the sort controls: a "Sort"
    -- label, one chip per key and the class-first dropdown. onChange
    -- re-renders whichever board the row belongs to. opts.menuStrata lifts
    -- the dropdown's menu for a board that sits above the usual windows;
    -- opts.compact is for the compact board at its narrowest, where six
    -- chips and the dropdown only fit without the label and a size down.
    --
    -- The chips are a framework segmented control with its radio click
    -- taken over, because several can be on at once here: each one in use
    -- wears the selected look, the column-header arrow (flipped when that
    -- key is reversed) and, when there is more than one, its place in the
    -- order as a small number in the corner. The label itself never
    -- changes, so a chip is as wide with a number as without.
    --
    -- Returns a handle: handle:Sync() makes the controls show what is
    -- saved (the other board may have changed it), handle:Recalc() lays
    -- the chips out again after the row was moved to a new parent.
    local function BuildSortControls(host, onChange, opts)
        opts = opts or {}
        if not opts.compact then
            local label = RC:CreateFontString(host, "OVERLAY", nil, 10)
            label:SetPoint("LEFT", host, "LEFT", 0, 0)
            label:SetText(RCL["Sort"])
            local lc = RC:GetColor("text", "gray")
            label:SetTextColor(lc.r, lc.g, lc.b, 1)
        end

        local handle = {}

        -- ---- class listed first
        -- Closed and with nothing picked it reads as its own label; the
        -- row has no room for a caption beside it.
        local NONE = "none"
        local classItems = { { text = RCL["None"], value = NONE } }
        local classText = { [NONE] = RCL["Class first"] }
        do
            local sorted = {}
            for _, token in ipairs(BOARD_CLASSES) do sorted[#sorted + 1] = token end
            table.sort(sorted, function(x, y) return ClassLabel(x) < ClassLabel(y) end)
            for _, token in ipairs(sorted) do
                classItems[#classItems + 1] = { text = ClassLabel(token), value = token }
                classText[token] = ClassLabel(token)
            end
        end
        local classDD = RC.UI:CreateScrollableDropdown(host, 96, classText[TopClass() or NONE], #classItems)
        classDD:SetPoint("RIGHT", host, "RIGHT", 0, 0)
        classDD:SetHeight(22)
        classDD:SetItems(classItems, function(value)
            SaveSort("boardSortTopClass", (value ~= NONE) and value or "")
            handle:Sync()
            onChange()
        end)
        if classDD.SetSearchEnabled then classDD:SetSearchEnabled(false) end
        if opts.menuStrata and classDD.GetName then
            local menu = classDD.menu or _G[(classDD:GetName() or "") .. "_Menu"]
            if menu then menu:SetFrameStrata(opts.menuStrata) end
        end
        classDD:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local gold = RC:GetColor("text", "gold")
            local norm = RC:GetColor("text", "normal")
            GameTooltip:SetText(RCL["Class first"], gold.r, gold.g, gold.b)
            GameTooltip:AddLine(RCL["Every toon of this class is listed before the others, right under your own character. The sort still applies inside each group."], norm.r, norm.g, norm.b, true)
            GameTooltip:Show()
        end)
        classDD:HookScript("OnLeave", function() GameTooltip:Hide() end)

        -- ---- the sort keys
        local segHost = CreateFrame("Frame", nil, host)
        segHost:SetPoint("LEFT",  host, "LEFT",  opts.compact and 0 or 32, 0)
        segHost:SetPoint("RIGHT", host, "RIGHT", -104, 0)
        segHost:SetHeight(20)
        local segments = RC.UI:CreateSegmentedControl(segHost, {
            items = SORT_ITEMS, inset = 0, y = 0, height = 20,
            fontSize = opts.compact and 10 or nil,
            -- sort chips, not a one-of-N value: several keys at once
            buttons = true,
        })

        local function Apply(order)
            local text = SortOrderText(order)
            if text ~= SortOrderText(SortOrder()) then
                SaveSort("boardSort", text)
                handle:Sync()
                onChange()
            end
        end

        local function OnChipClick(seg, button)
            local key = seg.segmentKey
            local order, at = {}, nil
            for i, entry in ipairs(SortOrder()) do
                order[i] = { key = entry.key, reversed = entry.reversed }
                if entry.key == key then at = i end
            end
            local add = IsShiftKeyDown and IsShiftKeyDown()
            if button == "RightButton" then
                if at then
                    order[at].reversed = not order[at].reversed
                elseif add then
                    order[#order + 1] = { key = key, reversed = true }
                else
                    order = { { key = key, reversed = true } }
                end
            elseif add then
                if not at then
                    order[#order + 1] = { key = key, reversed = false }
                elseif #order > 1 then
                    -- the last key stays: the board is always sorted by something
                    table.remove(order, at)
                end
            else
                order = { { key = key, reversed = at and order[at].reversed or false } }
            end
            Apply(order)
        end

        for _, seg in ipairs(segments.segments or {}) do
            seg:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            seg:SetScript("OnClick", OnChipClick)
            -- the arrow Blizzard's own sortable column headers use
            local arrow = seg:CreateTexture(nil, "OVERLAY")
            arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
            if opts.compact then
                -- a chip here is about 52 wide and "Online" takes most of it
                arrow:SetSize(7, 6)
                arrow:SetPoint("RIGHT", seg, "RIGHT", -2, 0)
                -- the size the font system re-applies when the font changes
                seg.text._wrFontSize = 10
            else
                arrow:SetSize(9, 8)
                arrow:SetPoint("RIGHT", seg, "RIGHT", -3, 0)
            end
            arrow:Hide()
            seg.sortArrow = arrow
            local rank = RC:CreateFontString(seg, "OVERLAY", nil, 8)
            rank:SetPoint("TOPLEFT", seg, "TOPLEFT", 2, -2)
            local rc = RC:GetColor("text", "gold")
            rank:SetTextColor(rc.r, rc.g, rc.b, 1)
            rank:Hide()
            seg.sortRank = rank
        end

        local shownFor
        function handle:Sync()
            local order = SortOrder()
            local top = TopClass() or NONE
            local sig = SortOrderText(order) .. "|" .. top
            if sig == shownFor then return end
            shownFor = sig
            local place = {}
            for i, entry in ipairs(order) do place[entry.key] = i end
            for _, seg in ipairs(segments.segments or {}) do
                local at = place[seg.segmentKey]
                -- room for the arrow: the label slides left a little
                seg.text:ClearAllPoints()
                seg.text:SetPoint("CENTER", seg, "CENTER", at and (opts.compact and -2 or -3) or 0, 0)
                seg:SetSelected(at ~= nil)
                seg:Repaint()
                if seg.sortRank then
                    local numbered = (at ~= nil) and #order > 1
                    seg.sortRank:SetText(numbered and tostring(at) or "")
                    seg.sortRank:SetShown(numbered)
                end
                if seg.sortArrow then
                    seg.sortArrow:SetShown(at ~= nil)
                    if at and order[at].reversed then
                        seg.sortArrow:SetTexCoord(0, 0.5625, 1, 0)
                    else
                        seg.sortArrow:SetTexCoord(0, 0.5625, 0, 1)
                    end
                end
            end
            -- always, not only when the value differs: picking "None" from
            -- the menu leaves the box reading "None", and closed it should
            -- read as its label again
            if classDD.SetSelectedValue then classDD:SetSelectedValue(top, classText[top]) end
        end

        function handle:Recalc()
            if segments.Recalc then segments:Recalc() end
        end

        handle.segments, handle.classDropdown = segments, classDD
        handle:Sync()
        return handle
    end

    -- Buff cells are pooled on the row and addressed by column index, so a
    -- row the mini board reuses rewrites its textures instead of stacking a
    -- fresh set on top of the old ones. What the tooltip says lives on the
    -- hit frame for the same reason a pooled row's name tooltip does.
    -- BuildRow hands out a brand new row every time, so for the sidebar page
    -- the pool is always empty and nothing about it changes.
    local function MakeCell(row, def, x, state, secs, sz, idx)
        sz = sz or ICON
        row.cells = row.cells or {}
        idx = idx or (#row.cells + 1)

        local cell = row.cells[idx]
        if not cell then
            local newIcon = row:CreateTexture(nil, "ARTWORK")
            newIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

            local newBorder = row:CreateTexture(nil, "BACKGROUND")
            newBorder:SetPoint("TOPLEFT", newIcon, "TOPLEFT", -1, 1)
            newBorder:SetPoint("BOTTOMRIGHT", newIcon, "BOTTOMRIGHT", 1, -1)

            local newTxt = RC:CreateFontString(row, "OVERLAY", nil, math.max(7, math.floor(sz * 0.4)))
            newTxt:SetPoint("TOP", newIcon, "BOTTOM", 0, -1)
            RC.UI:TagElement(newTxt, "wbTime")

            local newHit = CreateFrame("Frame", nil, row)
            newHit:SetAllPoints(newIcon)
            newHit:EnableMouse(true)
            newHit:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(self.cellLabel or RCL["Buff"])
                if self.cellState == "booned" then
                    local cc = RC:GetColor("text", "green"); GameTooltip:AddLine(RCL["Booned: "] .. FmtTime(self.cellSecs), cc.r, cc.g, cc.b)
                elseif self.cellState == "active" then
                    local cc = RC:GetColor("text", "yellow"); GameTooltip:AddLine(RCL["Active: "] .. FmtTime(self.cellSecs), cc.r, cc.g, cc.b)
                else
                    local cc = RC:GetColor("text", "red"); GameTooltip:AddLine(RCL["Missing"], cc.r, cc.g, cc.b)
                end
                GameTooltip:Show()
            end)
            newHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

            cell = { icon = newIcon, border = newBorder, txt = newTxt, hit = newHit }
            row.cells[idx] = cell
        end

        local icon, border, txt = cell.icon, cell.border, cell.txt
        icon:SetSize(sz, sz)
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", row, "TOPLEFT", x, -2)
        local tex = def.icon
        if not tex then
            tex = select(3, GetSpellInfo(def.ids[1]))
            def.icon = tex
        end
        icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
        StyleFont(txt, WBLook().timeFont, math.max(7, math.floor(sz * 0.4)))

        cell.hit.cellLabel = def.name or def.short or RCL["Buff"]
        cell.hit.cellState = state
        cell.hit.cellSecs  = secs

        if state == "active" then
            icon:SetDesaturated(false)
            icon:SetVertexColor(1, 1, 1, 1)
            local c = StateColor("active")
            border:SetColorTexture(c.r, c.g, c.b, 1)
            txt:SetText(TimerText(secs, "time"))
            txt:SetTextColor(c.r, c.g, c.b, 1)
        elseif state == "booned" then
            icon:SetDesaturated(false)
            icon:SetVertexColor(1, 1, 1, 1)
            local c = StateColor("booned")
            border:SetColorTexture(c.r, c.g, c.b, 1)
            txt:SetText(TimerText(secs, "time"))
            txt:SetTextColor(c.r, c.g, c.b, 1)
        else
            icon:SetDesaturated(true)
            icon:SetVertexColor(0.35, 0.35, 0.35, 1)
            local c = StateColor("missing")
            border:SetColorTexture(c.r, c.g, c.b, 1)
            txt:SetText("-")
            txt:SetTextColor(c.r, c.g, c.b, 0.8)
        end

        PlaceText(txt, "time", "TOP", icon, "BOTTOM", 0, -1, CellTo(row, cell))
        icon:Show(); border:Show(); txt:Show(); cell.hit:Show()
    end

    -- Hides pooled buff cells past `from`, for when the board loses a column
    -- (a festival buff ending) and a reused row still owns the old cell.
    local function HideCellsFrom(row, from)
        if not row.cells then return end
        for i = from, #row.cells do
            local cell = row.cells[i]
            cell.icon:Hide(); cell.border:Hide(); cell.txt:Hide(); cell.hit:Hide()
        end
    end

    -- Cooldown cells pool exactly like MakeCell, in their own per-row list.
    -- `stored` (chronoboon cell only) renders a booned row as "Stored";
    -- a running cooldown still wins over it.
    local function MakeCDCell(row, iconTex, x, remaining, sz, label, cellW, count, idx, stored)
        sz = sz or ICON
        row.cdCells = row.cdCells or {}
        idx = idx or (#row.cdCells + 1)

        local cell = row.cdCells[idx]
        if not cell then
            local newIcon = row:CreateTexture(nil, "ARTWORK")
            newIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

            local newTxt = RC:CreateFontString(row, "OVERLAY", nil, math.max(6, math.floor(sz * 0.35)))
            newTxt:SetPoint("TOP", newIcon, "BOTTOM", 0, -1)
            RC.UI:TagElement(newTxt, "wbCd")

            local newHit = CreateFrame("Frame", nil, row)
            newHit:SetAllPoints(newIcon)
            newHit:EnableMouse(true)
            newHit:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(self.cellLabel or "")
                local cdCount = self.cellCount
                if self.cellRemaining and self.cellRemaining > 0 then
                    local cc = RC:GetColor("text", "orange"); GameTooltip:AddLine(FmtTime(self.cellRemaining) .. RCL[" remaining"], cc.r, cc.g, cc.b)
                elseif self.cellStored then
                    local cc = RC:GetColor("text", "green"); GameTooltip:AddLine(RCL["Buffs stored in Chronoboon"], cc.r, cc.g, cc.b)
                elseif cdCount ~= nil and cdCount <= 0 then
                    local cc = RC:GetColor("text", "red"); GameTooltip:AddLine(RCL["No Chronoboon Displacers in bags"], cc.r, cc.g, cc.b)
                else
                    local cc = RC:GetColor("text", "green"); GameTooltip:AddLine(RCL["Ready"], cc.r, cc.g, cc.b)
                end
                if cdCount ~= nil then
                    local gc = RC:GetColor("text", "gray")
                    GameTooltip:AddLine(cdCount .. RCL[" Chronoboon Displacer"] .. (cdCount == 1 and "" or "s") .. RCL[" in bags"], gc.r, gc.g, gc.b)
                end
                GameTooltip:Show()
            end)
            newHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

            cell = { icon = newIcon, txt = newTxt, hit = newHit }
            row.cdCells[idx] = cell
        end

        local icon, txt = cell.icon, cell.txt
        icon:SetSize(sz, sz)
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", row, "TOPLEFT", x, -2)
        icon:SetTexture(iconTex or "Interface\\Icons\\INV_Misc_QuestionMark")

        if count ~= nil then
            local cf = cell.countFs
            if not cf then
                cf = RC:CreateFontString(row, "OVERLAY", nil, math.max(8, math.floor(sz * 0.46)), "OUTLINE")
                cf:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, 0)
                RC.UI:TagElement(cf, "wbCount")
                cell.countFs = cf
            end
            PlaceText(cf, "count", "BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, 0, CellTo(row, cell))
            StyleFont(cf, WBLook().timeFont, math.max(8, math.floor(sz * 0.46)))
            cf:SetText(tostring(count))
            local cc = RC:GetColor("text", (count > 0) and "gold" or "red")
            cf:SetTextColor(cc.r, cc.g, cc.b, 1)
            cf:Show()
        elseif cell.countFs then
            cell.countFs:Hide()
        end

        StyleFont(txt, WBLook().timeFont, math.max(6, math.floor(sz * 0.35)))
        if cellW and cellW > 0 then
            txt:SetWidth(cellW)
            txt:SetJustifyH("CENTER")
            txt:SetWordWrap(false)
        end

        cell.hit.cellLabel     = label
        cell.hit.cellRemaining = remaining
        cell.hit.cellCount     = count
        cell.hit.cellStored    = stored and true or nil

        if remaining and remaining > 0 then
            icon:SetDesaturated(true)
            icon:SetVertexColor(0.7, 0.7, 0.7, 1)
            local c = RC:GetColor("text", "orange")
            txt:SetText(TimerText(remaining, "cd"))
            txt:SetTextColor(c.r, c.g, c.b, 1)
        elseif stored then
            icon:SetDesaturated(false)
            icon:SetVertexColor(1, 1, 1, 1)
            local c = RC:GetColor("text", "green")
            txt:SetText(RCL["Stored"])
            txt:SetTextColor(c.r, c.g, c.b, 1)
        elseif count ~= nil and count <= 0 then
            icon:SetDesaturated(true)
            icon:SetVertexColor(0.7, 0.7, 0.7, 1)
            local c = RC:GetColor("text", "red")
            txt:SetText(RCL["None"])
            txt:SetTextColor(c.r, c.g, c.b, 1)
        else
            icon:SetDesaturated(false)
            icon:SetVertexColor(1, 1, 1, 1)
            local c = RC:GetColor("text", "green")
            txt:SetText(RCL["Ready"])
            txt:SetTextColor(c.r, c.g, c.b, 1)
        end

        PlaceText(txt, "cd", "TOP", icon, "BOTTOM", 0, -1, CellTo(row, cell))
        icon:Show(); txt:Show(); cell.hit:Show()
    end

    -- The sidebar page's sort row, kept across re-renders.
    local pageSortHost, pageSortCtl

    local function BuildRow(card, info, rowY)
        local WB = RC.WorldBuffs
        local row = CreateFrame("Frame", nil, card)
        row:SetPoint("TOPLEFT", card, "TOPLEFT", 12, rowY)
        row:SetPoint("RIGHT", card, "RIGHT", -12, 0)
        row:SetHeight(ROWH)
        if not info.online then row:SetAlpha(0.5) end

        local nameFs = RC:CreateFontString(row, "OVERLAY", nil, 12)
        nameFs:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
        nameFs:SetWidth(NAMEW)
        nameFs:SetJustifyH("LEFT")
        nameFs:SetWordWrap(false)
        nameFs:SetText(StripRealm(info.name))
        StyleFont(nameFs, WBLook().nameFont, 12)
        row.nameFs = nameFs
        local nc = ClassColor(info.class) or (info.isLocal and RC:GetColor("text", "gold") or RC:GetColor("ui", "headerText"))
        nameFs:SetTextColor(nc.r, nc.g, nc.b, 1)

        local subFs = RC:CreateFontString(row, "OVERLAY", nil, 10)
        StyleFont(subFs, WBLook().subFont, 10)
        subFs:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -20)
        subFs:SetWidth(NAMEW)
        subFs:SetJustifyH("LEFT")
        subFs:SetWordWrap(false)
        local subText, subColor = SublineFor(info)
        subFs:SetText(subText)
        subFs:SetTextColor(subColor.r, subColor.g, subColor.b, 1)
        row.subFs = subFs
        PlaceText(nameFs, "name", "TOPLEFT", row, "TOPLEFT", 0, -2, RowTo(row))
        PlaceText(subFs, "sub", "TOPLEFT", row, "TOPLEFT", 0, -20, RowTo(row))

        AttachNameTooltip(row, info, NAMEW, ROWH)

        local x = ICON_X0
        for _, def in ipairs(BoardDefs()) do
            local secs  = info.buffs and info.buffs[def.key]
            local state = secs and ((info.frozen and info.frozen[def.key]) and "booned" or "active") or "missing"
            MakeCell(row, def, x, state, secs)
            x = x + ICON_GAP
        end
        x = x + 10
        MakeCDCell(row, CHRONO_ICON, x, info.cd, ICON, "Chronoboon re-use", ICON_GAP, info.chrono, nil, info.booned); x = x + ICON_GAP
        MakeCDCell(row, HS_ICON, x, info.hs, ICON, "Hearthstone", ICON_GAP); x = x + ICON_GAP
        MakeCDCell(row, DMF_ICON, x, DmfShow(info), ICON, DMF_CD_TIP, ICON_GAP)

        -- Removing an offline peer writes through WB (mesh roster), not
        -- RC.db, then forces an immediate re-render (preserveScroll=true)
        -- so the row disappears without waiting for the panel ticker.
        if not info.isLocal and not info.online and WB and WB.RemovePeer then
            local toonName = info.name
            local del = RC.UI:CreateXCloseButton(card, 20, function()
                RC.UI:CreateConfirmDialog(
                    RCL["Remove Toon"],
                    RCL["Remove "] .. StripRealm(toonName) .. RCL[" from the World Buff board?\n\n"]
                        .. RCL["This tells the mesh to forget it too. It reappears only if it comes back online and shares again."],
                    function()
                        WB:RemovePeer(toonName)
                        local outer = RC.sidebarConfigFrame
                        local compat = outer and outer.compatFrame
                        if compat then RC:ShowSidebarWorldBuffs(compat, true) end
                    end,
                    nil, RCL["Remove"], true)
            end)
            del:SetPoint("RIGHT", row, "RIGHT", -10, 0)
        end

        return rowY - ROWH
    end

    -- COMPACT BOARD PREVIEW: three made-up toons drawn by the board's own
    -- row code (NewMiniRow / FillMiniRow), so every look setting shows.
    local K = RC._disp
    -- two rows of the board at its narrowest (booned, active, missing and
    -- the stripe all show); update sizes the canvas to them
    local WB_PV_W, WB_PV_H = 400, 88
    -- the drop strip's three looks: a timer, ready, not known
    local FAKE_DROPS = {
        { key = "warchief", label = RCL["Rend"], id = 16609, known = true, cdRemaining = 4200 },
        { key = "rally", label = RCL["Onyxia"], id = 22888, known = true, cdRemaining = 0 },
        { key = "songflower", label = RCL["Songflower"], id = 15366, known = false },
    }
    local function FakeRoster()
        local defs = BoardDefs()
        local function buffs(n, frozen)
            local b, f = {}, {}
            for i, d in ipairs(defs) do
                if i <= n then b[d.key] = 3600 + i * 600 if frozen then f[d.key] = true end end
            end
            return b, f
        end
        local b1, f1 = buffs(#defs, true)
        local b2 = buffs(math.max(1, #defs - 2))
        return {
            { name = "Zaccw", class = "WARRIOR", level = 60, online = true, isLocal = true, buffs = b1, frozen = f1, count = #defs, booned = true, chrono = 3, location = "Orgrimmar" },
            { name = "Zacdruid", class = "DRUID", level = 60, online = true, buffs = b2, frozen = {}, count = #defs - 2, cd = 1800, chrono = 1, location = "Naxxramas" },
            { name = "Zacmage", class = "MAGE", level = 60, online = false, buffs = {}, frozen = {}, count = 0, chrono = 0, location = "Stormwind" },
        }
    end
    local function WBPreviewBuild(canvas, P)
        local holder = CreateFrame("Frame", nil, canvas)
        holder:SetPoint("CENTER", canvas, "CENTER", 0, 0)
        holder:SetSize(WB_PV_W - 12, WB_PV_H - 12)
        P.store.holder = holder
        P.store.rows = {}
        -- a click on a sample text opens the Text tab on its controls
        RC.UI:PickOnClick(holder, "worldbuffs.board")
        -- "Whole board": the board's own window (title bar, filter row,
        -- sort row, scroll area, drop strip, resize grip), inert
        local M = RC._wbMini
        if M and M.NewWindow then
            local win = M.NewWindow(canvas)
            win:SetPoint("CENTER", canvas, "CENTER", 0, 0)
            win:Hide()
            RC.UI:PickOnClick(win, "worldbuffs.board")
            P.store.win = win
        end
    end
    local function WBPreviewUpdate(canvas, P)
        local M = RC._wbMini
        if not M then return end
        if not RC._wbBoardDefs then
            local WB = RC.WorldBuffs
            local out = {}
            for _, d in ipairs((WB and WB.BUFFS) or {}) do if not d.festival then out[#out + 1] = d end end
            RC._wbBoardDefs = out
        end
        local holder = P.store.holder
        local win = P.store.win
        if win and P.mode == "window" then
            holder:Hide()
            win:Show()
            local w, h = M.FillWindow(win, FakeRoster(), FAKE_DROPS)
            -- the canvas is the window's box; the strip shows it at real size
            P.Resize(w + 8, h + 8)
            return
        end
        if win then win:Hide() end
        holder:Show()
        local roster = FakeRoster()
        -- the board's rows as they sit on the board at its own width
        -- (scale 1, every sample toon), at their real size
        local cw = (M.MinWidth and M.MinWidth() or WB_PV_W) - 16
        local G = M.Geom(cw, 1)
        local y = 0
        for i, info in ipairs(roster) do
            local row = P.store.rows[i]
            if not row then
                row = M.NewRow(holder)
                P.store.rows[i] = row
            end
            M.FillRow(row, info, i, G, holder, y, true)
            y = y - G.rowH
        end
        -- the canvas is the rows' box; the strip shows it at real size
        local w = math.max(cw, G.x0 + (#BoardDefs() + 3) * G.step)
        holder:SetSize(w, -y)
        P.Resize(w + 8, -y + 8)
    end
    -- the board's opening (its title bar's sheen and mark), played again
    local function WBPreviewReplay(canvas, P)
        local win = P.store.win
        if not (win and P.mode == "window" and win:IsShown()) then return end
        win:Hide()
        win:Show()
    end

    -- the Text positions card's rows (module level: the pooled pickers get
    -- every function through their opts)
    local function WBRoot() RC.db.worldBuffs = RC.db.worldBuffs or {} return RC.db.worldBuffs end
    local function WBTextsChanged()
        RC:SaveConfigurationToProfile()
        if RC._wbApplyLook then RC._wbApplyLook() end
    end
    local WB_TIME_KINDS = { time = true }
    local WBT_ROW = { value = "row", text = RCL["The row"] }
    local WBT_ICON = { value = "icon", text = RCL["The cell's icon"] }
    local WB_TEXT_ROWS = {
        { key = "name", pick = "wbName", label = RCL["Toon name position"], where = RCL["Top left of the row"],
          targets = { WBT_ROW, { value = "sub", text = RCL["Where they are"] } },
          defaults = function() return { point = "TOPLEFT", relPoint = "TOPLEFT", x = 0, y = -2 } end },
        { key = "sub", pick = "wbSub", label = RCL["Where they are position"], where = RCL["Under the name"],
          targets = { WBT_ROW, { value = "name", text = RCL["The toon name"] } },
          defaults = function() return { point = "TOPLEFT", relPoint = "TOPLEFT", x = 0, y = -18 } end },
        { key = "time", pick = "wbTime", label = RCL["Buff timers"], where = RCL["Under each buff"], format = true,
          targets = { WBT_ICON, WBT_ROW },
          sample = function(spec) return RC.UI:FormatText(spec, RC.WB_TIME_FORMAT, { value = 3480 }, { value = "time" }, "value") end,
          defaults = function() return { point = "TOP", relPoint = "BOTTOM", x = 0, y = -1 } end },
        { key = "cd", pick = "wbCd", label = RCL["Cooldown timers"], where = RCL["Under each cooldown"], format = true,
          targets = { WBT_ICON, WBT_ROW, { value = "count", text = RCL["The Chronoboon count"] } },
          sample = function(spec) return RC.UI:FormatText(spec, RC.WB_TIME_FORMAT, { value = 1800 }, { value = "time" }, "value") end,
          defaults = function() return { point = "TOP", relPoint = "BOTTOM", x = 0, y = -1 } end },
        { key = "count", pick = "wbCount", label = RCL["Chronoboon count position"], where = RCL["Bottom right of its icon"],
          targets = { WBT_ICON, WBT_ROW, { value = "cd", text = RCL["Its timer"] } },
          defaults = function() return { point = "BOTTOMRIGHT", relPoint = "BOTTOMRIGHT", x = 1, y = 0 } end },
    }

    -- (this page is read live, not by the search index: these words find
    -- the Text positions card)
    if RC.UI.RegisterSidebarSearch then
        RC.UI:RegisterSidebarSearch({
            keywords = { "board text positions", "toon name position", "where they are position", "buff timers",
                "cooldown timers", "chronoboon count position", "board timer format", "buff timer format" },
            parentId = "world_buffs", tabKey = "textpos", tabLabel = RCL["Text positions"],
            setTab = function(f) local c = f and (f.compatFrame or f) if c then c.wbTab = "text" end end,
            scrollTo = "Text positions",
        })
    end

    local function BuildLookTabs(self, parent, yPos, tab)
        local function L() return K.Look(RC.db.worldBuffs, "look") end
        local function Apply() if RC._wbApplyLook then RC._wbApplyLook() end end
        if tab == "look" then
            yPos = K.Card(parent, yPos, RCL["Compact board"], function(card, y)
                y = K.Slider(card, y, RCL["Cell size"], 14, 40, L().iconSize or 20, 1,
                    function(v) return v .. RCL[" px"] end, function(v) L().iconSize = v RC:SaveConfigurationToProfile() Apply() end)
                y = K.Slider(card, y, RCL["Row height"], 26, 70, L().rowHeight or 38, 1,
                    function(v) return v .. RCL[" px"] end, function(v) L().rowHeight = v RC:SaveConfigurationToProfile() Apply() end)
                y = K.Desc(card, y + 6, RCL["Sizes at the board's narrowest; widening the window still scales everything up."])
                y = K.Check(card, y, RCL["Stripe every other row"], function() return L().stripes ~= false end,
                    function(v) L().stripes = v Apply() end)
                return y
            end)
            yPos = K.Card(parent, yPos, RCL["Buff colours"], function(card, y)
                y = K.Desc(card, y, RCL["The ring and timer of each buff cell, on the compact board and this page alike."])
                y = K.LookColor(card, y, RCL["Booned (stored)"], L, "boonedColor", function() return RC:GetColor("text", "green") end, Apply)
                y = K.LookColor(card, y, RCL["Active (not booned)"], L, "activeColor", function() return RC:GetColor("text", "yellow") end, Apply)
                y = K.LookColor(card, y, RCL["Missing"], L, "missingColor", function() return RC:GetColor("text", "red") end, Apply)
                return y - 4
            end)
            -- the compact board window: fade, edge, layer (RC:ApplyFrameCustom)
            local function Root() return RC.db.worldBuffs end
            local function Ensure() RC.db.worldBuffs = RC.db.worldBuffs or {} return RC.db.worldBuffs end
            local function ApplyFrame() RC:SaveConfigurationToProfile() Apply() end
            yPos = self.UI:FrameVisibilityCard(parent, yPos, Root, ApplyFrame, { title = RCL["Board fade and opacity"], ensure = Ensure,
                note = RCL["On top of opening and closing it yourself: a rule that is not met fades it out."] })
            yPos = self.UI:FrameChromeCard(parent, yPos, Root, ApplyFrame, { title = RCL["Board shadow and glow"], ensure = Ensure,
                fields = { shadowSize = true, shadowColor = true, glowSize = true, glowColor = true } })
            yPos = self.UI:FrameLayerCard(parent, yPos, Root, ApplyFrame, { title = RCL["Board layer and scale"], ensure = Ensure })
        else
            yPos = K.Card(parent, yPos, RCL["Text"], function(card, y)
                y = K.Font(card, y, RCL["Toon names"], function() return L().nameFont end,
                    function(spec) L().nameFont = spec Apply() end, { size = 11, outline = "OUTLINE" }, "Zaccw  Zacdruid", 6, 24)
                y = K.Font(card, y, RCL["Where they are"], function() return L().subFont end,
                    function(spec) L().subFont = spec Apply() end, { size = 9, outline = "OUTLINE" }, "Orgrimmar  needs buffs", 6, 24)
                y = K.Font(card, y, RCL["Timers"], function() return L().timeFont end,
                    function(spec) L().timeFont = spec Apply() end, { size = 8, outline = "OUTLINE" }, "58m  12m  Ready", 6, 24)
                return K.Desc(card, y + 4, RCL["Sizes follow the board until you set one here; a size you set stays put when the board is widened."])
            end)
            -- where each text sits (worldBuffs.anchors.*) and how the timers
            -- read (worldBuffs.formats.time / .cd); nothing set = the board as it is
            yPos = K.Card(parent, yPos, RCL["Text positions"], function(card, y)
                local cw = card:GetWidth() or 0
                local W = (cw > 240) and math.min(460, cw - 28) or 420
                for _, r in ipairs(WB_TEXT_ROWS) do
                    local ag, as = self.UI:CustomAccess(WBRoot, "anchors", r.key, WBTextsChanged)
                    local o = { label = r.label, key = r.pick, width = W, anchorGet = ag, anchorSet = as,
                        targets = r.targets, defaultTargetLabel = r.where, anchorDefaults = r.defaults }
                    if r.format then
                        o.formatGet, o.formatSet = self.UI:CustomAccess(WBRoot, "formats", r.key, WBTextsChanged)
                        o.formatDefaults, o.formatKinds, o.formatSample = RC.WB_TIME_FORMAT, WB_TIME_KINDS, r.sample
                    end
                    local g = self.UI:CreateTextElement(card, o)
                    g:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
                    y = y - g:GetHeight() - 12
                end
                return K.Desc(card, y + 4, RCL["On the compact board and the Board tab alike. Reset puts a text back where the board puts it."])
            end)
        end
        self:UpdateSidebarScrollbar(self.sidebarConfigFrame, math.abs(yPos))
    end

    -- preserveScroll=true keeps scroll position across in-place refreshes
    -- (peer removal, ticker re-render); ClearSidebarContent() does the
    -- actual GetVerticalScroll/SetVerticalScroll capture-restore.
    function RC:ShowSidebarWorldBuffs(frame, preserveScroll)
        self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
        local parent = frame.scrollChild
        if not parent then return end
        local WB = self.WorldBuffs
        local cfg = (self.db and self.db.worldBuffs) or {}
        local yPos = -20

        local meshOn = self.MeshSync and self.MeshSync.IsEnabled and self.MeshSync:IsEnabled()

        local tab = frame.wbTab or "board"
        frame.wbTab = tab
        if RC.CustomPick then
            RC.CustomPick.SetHandler("worldbuffs.board", function(k)
                local cf = RC.sidebarConfigFrame and RC.sidebarConfigFrame.compatFrame
                if not cf or type(k) ~= "string" or not k:find("^wb") then return end
                cf.wbTab = "text"
                RC:ShowSidebarWorldBuffs(cf, true)
            end)
        end
        self.UI:DeclarePreview({
            key = "worldbuffs.board", title = RCL["Compact board"],
            width = WB_PV_W, height = WB_PV_H,
            build = WBPreviewBuild, update = WBPreviewUpdate, replay = WBPreviewReplay,
            modes = { { id = "rows", label = RCL["Rows"] }, { id = "window", label = RCL["Whole board"] } },
            modesLabel = RCL["Show"],
        })
        -- the title first (it pins above the preview strip), then the tabs
        local _, hy = self:CreateSettingsPageHeader(parent, yPos, RCL["World Buffs"],
            RCL["Who has which world buff, on every toon the Mesh Network shares"],
            "Interface\\Icons\\INV_Misc_Head_Dragon_01")
        yPos = hy
        yPos = K.Tabs(parent, yPos, { { "board", RCL["Board"] }, { "look", RCL["Look"] }, { "text", RCL["Text"] } },
            tab, function(k)
                frame.wbTab = k
                RC:ShowSidebarWorldBuffs(frame, true)
            end)
        if tab ~= "board" then
            BuildLookTabs(self, parent, yPos, tab)
            return
        end

        local headCard = self:CreateSettingsCard(parent, yPos, RCL["World buff board"])

        local statusFs = self:CreateFontString(headCard, "OVERLAY", nil, 11)
        statusFs:SetPoint("TOPLEFT", headCard, "TOPLEFT", 14, -34)
        statusFs:SetPoint("RIGHT", headCard, "RIGHT", -14, 0)
        statusFs:SetJustifyH("LEFT")
        local online, tracked = 0, 0
        if WB and WB.Counts then online, tracked = WB:Counts() end
        if meshOn then
            local c = self:GetColor("text", "green")
            statusFs:SetText(RCL["Sharing ON via Mesh Network - "] .. online .. RCL[" online, "] .. tracked .. RCL[" tracked."])
            statusFs:SetTextColor(c.r, c.g, c.b, 1)
        else
            local c = self:GetColor("text", "orange")
            statusFs:SetText(RCL["Sharing OFF. Enable the Mesh Network (Mesh tab) to share and see other toons; your own buffs still show below."])
            statusFs:SetTextColor(c.r, c.g, c.b, 1)
        end
        headCard:SetHeight(70)
        yPos = yPos - headCard:GetHeight() - 12

        local openBtn = self.UI:CreateDynamicButton(headCard, "Open compact board", 22, 10, 80)
        openBtn:SetPoint("TOPRIGHT", headCard, "TOPRIGHT", -12, -8)
        openBtn:SetScript("OnClick", function()
            if self.ToggleWorldBuffMini then self:ToggleWorldBuffMini() end
        end)

        local hintFs = self:CreateFontString(parent, "OVERLAY", nil, 10)
        hintFs:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, yPos - 2)
        hintFs:SetPoint("RIGHT", parent, "RIGHT", -14, 0)
        hintFs:SetJustifyH("LEFT")
        hintFs:SetText(RCL["Tip: type /wb to pop up the compact board anywhere."])
        local hc = self:GetColor("text", "gray")
        hintFs:SetTextColor(hc.r, hc.g, hc.b, 1)
        yPos = yPos - 20

        local roster = (WB and WB.GetRoster and WB:GetRoster()) or {}

        -- Must run before BuildRow() below - BuildRow -> MakeCell reads
        -- RC._wbBoardDefs via BoardDefs() to lay out per-toon columns.
        do
            local defs = (WB and WB.BUFFS) or {}
            local out = {}
            for _, d in ipairs(defs) do
                local show = not d.festival
                if not show then
                    for _, info in ipairs(roster) do
                        if info.buffs and info.buffs[d.key] then show = true; break end
                    end
                end
                if show then out[#out + 1] = d end
            end
            RC._wbBoardDefs = out
        end

        local listCard = self:CreateSettingsCard(parent, yPos, RCL["Toons"])
        if #roster == 0 then
            local empty = self:CreateFontString(listCard, "OVERLAY", nil, 11)
            empty:SetPoint("TOPLEFT", listCard, "TOPLEFT", 14, -30)
            empty:SetText(RCL["No toons reporting yet."])
            local ec = self:GetColor("text", "gray")
            empty:SetTextColor(ec.r, ec.g, ec.b, 1)
            listCard:SetHeight(54)
        else
            -- The page is rebuilt every couple of seconds; the sort row is
            -- built once and moved onto each new card instead of being
            -- thrown away with the old one.
            local firstBuild = not pageSortHost
            if firstBuild then
                pageSortHost = CreateFrame("Frame", nil, listCard)
                pageSortHost:SetHeight(22)
            end
            pageSortHost:SetParent(listCard)
            pageSortHost:ClearAllPoints()
            pageSortHost:SetPoint("TOPLEFT",  listCard, "TOPLEFT",  14, -30)
            pageSortHost:SetPoint("TOPRIGHT", listCard, "TOPRIGHT", -14, -30)
            pageSortHost:Show()
            if firstBuild then
                -- Next frame, not inline: the re-render must not run inside
                -- the row's own click handler.
                pageSortCtl = BuildSortControls(pageSortHost, function()
                    C_Timer.After(0, function()
                        local outer = RC.sidebarConfigFrame
                        local compat = outer and outer.compatFrame
                        if compat and outer:IsShown() and RC.SidebarState
                           and RC.SidebarState.selectedItem == "world_buffs" then
                            RC:ShowSidebarWorldBuffs(compat, true)
                        end
                    end)
                end)
            end
            pageSortCtl:Sync()
            -- A new card of the same width fires no size change, so the
            -- segments are laid out by hand.
            pageSortCtl:Recalc()
            SortRoster(roster)
            local rowY = -60
            for _, info in ipairs(roster) do
                rowY = BuildRow(listCard, info, rowY)
            end
            listCard:SetHeight(math.abs(rowY) + 10)
        end
        yPos = yPos - listCard:GetHeight() - 12

        local legCard = self:CreateSettingsCard(parent, yPos, RCL["Legend"])
        local function Swatch(x, colorKey, label)
            local sw = legCard:CreateTexture(nil, "ARTWORK")
            sw:SetSize(12, 12)
            sw:SetPoint("TOPLEFT", legCard, "TOPLEFT", x, -32)
            local c = StateColor(colorKey)
            sw:SetColorTexture(c.r, c.g, c.b, 1)
            local lf = RC:CreateFontString(legCard, "OVERLAY", nil, 10)
            lf:SetPoint("LEFT", sw, "RIGHT", 5, 0)
            lf:SetText(label)
            lf:SetTextColor(c.r, c.g, c.b, 1)
            return lf
        end
        Swatch(14, "booned", "booned (stored)")
        Swatch(150, "active", "active (not booned)")
        Swatch(310, "missing", "missing")
        local note = self:CreateFontString(legCard, "OVERLAY", nil, 10)
        note:SetPoint("TOPLEFT", legCard, "TOPLEFT", 14, -52)
        note:SetPoint("RIGHT", legCard, "RIGHT", -14, 0)
        note:SetJustifyH("LEFT")
        note:SetText(RCL["Booned times are frozen when stored; dimmed rows are offline toons (last-known, projected). Click the x on an offline toon to remove one added by mistake - it syncs over the mesh."])
        local noteC = self:GetColor("text", "gray")
        note:SetTextColor(noteC.r, noteC.g, noteC.b, 1)
        legCard:SetHeight(92)
        yPos = yPos - legCard:GetHeight() - 12

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame, math.abs(yPos))
        RC._wbEnsureTicker()
    end

    -- cell size and row height come from the look (these are the defaults)
    local function MiniIcon() return WBLook().iconSize or 20 end
    local function MiniRowH() return WBLook().rowHeight or 38 end
    local MINI_NAMEW    = 84
    local MINI_NAMEGAP  = 8
    local MINI_RIGHTPAD = 6
    local MINI_HEADER   = 30
    local MINI_SCROLLW  = 14
    local MINI_DROPS_H  = 22
    -- Two control rows: filters, then sort order.
    local MINI_CTRLROW  = 28
    local MINI_CTRLH    = MINI_CTRLROW * 2
    local miniFrame, miniContent, miniScroll, miniScrollBar, miniFooter, miniTicker, miniUserSized
    local miniSortCtl
    -- Mini board rows are pooled by position, not rebuilt: see RefreshMini.
    local miniRows = {}

    -- Column count follows BoardDefs(), so width/layout shift if the sidebar
    -- page's cache (RC._wbBoardDefs) picks up extra festival-buff columns.
    local function MiniColCount()
        return #BoardDefs() + 3
    end
    local function MiniMinWidth()
        local nCols = MiniColCount()
        return MINI_NAMEW + MINI_NAMEGAP + MiniIcon() + (nCols - 1) * (MiniIcon() + 6) + MINI_RIGHTPAD + 16 + MINI_SCROLLW
    end

    local function FmtCD(s)
        s = math.floor(s or 0)
        if s >= 3600 then
            local h = math.floor(s / 3600)
            local m = math.floor((s % 3600) / 60)
            return (m > 0) and (h .. "h" .. m .. "m") or (h .. "h")
        elseif s >= 60 then
            return math.floor(s / 60) .. "m"
        end
        return s .. "s"
    end

    -- The drop strip along the board's foot, one icon and timer per drop
    -- (the live board and the settings preview's sample alike). A
    -- sample's icons take no mouse (no tooltips).
    local function FillDrops(footer, drops, sample)
        footer.items = footer.items or {}

        local fw = footer:GetWidth() or 0
        if fw < 20 then fw = MiniMinWidth() - 16 end
        local n = #drops
        local slotW = (n > 0) and (fw / n) or fw
        -- Not the file-level ICON (24): the drop strip runs its own smaller
        -- icon size, and shadowing the outer name here read as a bug.
        local DROP_ICON = 16

        for i = 1, n do
            local it = footer.items[i]
            if not it then
                local icon = footer:CreateTexture(nil, "ARTWORK")
                icon:SetSize(DROP_ICON, DROP_ICON)
                icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                local fs = RC:CreateFontString(footer, "OVERLAY", nil, 10)
                fs:SetJustifyH("LEFT")
                it = { icon = icon, txt = fs }
                local hit = CreateFrame("Frame", nil, footer)
                hit:SetAllPoints(icon)
                hit:EnableMouse(not sample)
                hit:SetScript("OnEnter", function(self)
                    local dd = self.drop
                    if not dd then return end
                    GameTooltip:SetOwner(self, "ANCHOR_TOP")
                    GameTooltip:AddLine(dd.label or "")
                    local gray = RC:GetColor("text", "gray")
                    if dd.key == "songflower" then
                        local WB2 = RC.WorldBuffs
                        local nodes = (WB2 and WB2.GetSongflowerNodes and WB2:GetSongflowerNodes()) or {}
                        if #nodes == 0 then
                            GameTooltip:AddLine(dd.known and RCL["A node is up now."] or RCL["No data yet."], gray.r, gray.g, gray.b)
                        else
                            local oc = RC:GetColor("text", "orange")
                            for k = 1, math.min(#nodes, 10) do
                                local n = nodes[k]
                                local where
                                if n.name then
                                    where = n.name
                                elseif n.x and n.y then
                                    where = string.format(RCL["Felwood %.0f, %.0f"], n.x, n.y)
                                else
                                    where = "Node " .. n.idx
                                end
                                GameTooltip:AddLine(where .. ":  " .. FmtCD(n.rem), oc.r, oc.g, oc.b)
                            end
                        end
                    elseif dd.key == "rally" then
                        local mine = UnitFactionGroup("player") or "Alliance"
                        local opp  = (mine == "Horde") and "Alliance" or "Horde"
                        local oc = RC:GetColor("text", "orange")
                        local gc = RC:GetColor("text", "green")
                        local function facLine(fac, known2, rem2)
                            if not known2 then
                                GameTooltip:AddLine(fac .. RCL[": no data"], gray.r, gray.g, gray.b)
                            elseif (rem2 or 0) > 0 then
                                GameTooltip:AddLine(fac .. ": " .. FmtCD(rem2), oc.r, oc.g, oc.b)
                            else
                                GameTooltip:AddLine(fac .. RCL[": available now"], gc.r, gc.g, gc.b)
                            end
                        end
                        facLine(mine, dd.known, dd.cdRemaining)
                        facLine(opp, dd.oppRemaining ~= nil, dd.oppRemaining)
                    elseif not dd.known then
                        GameTooltip:AddLine(RCL["No data yet."], gray.r, gray.g, gray.b)
                    elseif (dd.cdRemaining or 0) > 0 then
                        local oc = RC:GetColor("text", "orange"); GameTooltip:AddLine(RCL["Next: "] .. FmtCD(dd.cdRemaining), oc.r, oc.g, oc.b)
                    else
                        local gc = RC:GetColor("text", "green"); GameTooltip:AddLine(RCL["Available now"], gc.r, gc.g, gc.b)
                    end
                    GameTooltip:Show()
                end)
                hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
                it.hit = hit
                footer.items[i] = it
            end
            local d = drops[i]
            if it.hit then it.hit.drop = d end

            local tex = d.id and select(3, GetSpellInfo(d.id))
            it.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")

            local x = (i - 1) * slotW + 4
            it.icon:ClearAllPoints()
            it.icon:SetPoint("LEFT", footer, "LEFT", x, 0)
            it.txt:ClearAllPoints()
            it.txt:SetPoint("LEFT", it.icon, "RIGHT", 4, 0)
            it.txt:SetWidth(slotW - DROP_ICON - 8)
            it.icon:Show(); it.txt:Show()

            local str, col
            if not d.known then
                str, col = "?", RC:GetColor("text", "gray")
                it.icon:SetDesaturated(true)
            elseif (d.cdRemaining or 0) > 0 then
                str, col = FmtCD(d.cdRemaining), (RC:GetColor("text", "orange") or RC:GetColor("text", "yellow"))
                it.icon:SetDesaturated(false)
            else
                str, col = "Ready", RC:GetColor("text", "green")
                it.icon:SetDesaturated(false)
            end
            it.txt:SetText(str)
            it.txt:SetTextColor(col.r, col.g, col.b, 1)
        end
        for i = n + 1, #footer.items do
            local it = footer.items[i]
            if it then it.icon:Hide(); it.txt:Hide() end
        end
    end
    local function RefreshDrops()
        local WB = RC.WorldBuffs
        if not miniFooter or not WB or not WB.GetDrops then return end
        FillDrops(miniFooter, WB:GetDrops())
    end

    -- A compact-board row's geometry for a content width and scale.
    local function MiniGeom(cw, scale)
        local G = {}
        G.iconSz   = math.floor(MiniIcon() * scale + 0.5)
        G.rowH     = math.floor(MiniRowH() * scale + 0.5)
        G.nameW    = math.floor(MINI_NAMEW * scale + 0.5)
        G.nameFont = math.max(8, math.floor(11 * scale + 0.5))
        G.subFont  = math.max(7, math.floor(9 * scale + 0.5))
        G.subY     = math.floor(18 * scale + 0.5)
        local nCols = MiniColCount()
        G.x0       = G.nameW + MINI_NAMEGAP
        local lastLeft = (cw - MINI_SCROLLW - MINI_RIGHTPAD) - G.iconSz
        local step     = (nCols > 1) and ((lastLeft - G.x0) / (nCols - 1)) or 0
        local minStep  = G.iconSz + 6
        if step < minStep then step = minStep end
        G.step = step
        return G
    end

    -- A pooled compact-board row (the board and the settings preview).
    local function NewMiniRow(parent)
        local row = CreateFrame("Frame", nil, parent)
        -- Faint stripe on every other row so a long board stays
        -- readable; white at 0.03 is the cap for stripes.
        row.stripe = row:CreateTexture(nil, "BACKGROUND")
        row.stripe:SetAllPoints()
        row.stripe:SetTexture("Interface\\Buttons\\WHITE8X8")
        row.nameFs = RC:CreateFontString(row, "OVERLAY", nil, 11)
        row.nameFs:SetJustifyH("LEFT")
        row.nameFs:SetWordWrap(false)
        row.subFs = RC:CreateFontString(row, "OVERLAY", nil, 9)
        row.subFs:SetJustifyH("LEFT")
        row.subFs:SetWordWrap(false)
        RC.UI:TagElement(row.nameFs, "wbName")
        RC.UI:TagElement(row.subFs, "wbSub")
        return row
    end

    -- Writes one toon into a row: name, where it is, a cell per buff and
    -- the three cooldown cells. noTip leaves the name tooltip off.
    local function FillMiniRow(row, info, i, G, parent, rowY, noTip)
        local iconSz, rowH, nameW, nameFont, subFont, subY, x0, step =
            G.iconSz, G.rowH, G.nameW, G.nameFont, G.subFont, G.subY, G.x0, G.step
        local sc = RC:GetColor("text", "white")
        row.stripe:SetVertexColor(sc.r, sc.g, sc.b, 0.03)
        row.stripe:SetShown(i % 2 == 0 and WBLook().stripes ~= false)

        -- Every geometry value below is scale-dependent, so a reused row
        -- has to re-anchor rather than just retext.
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, rowY)
        row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
        row:SetHeight(rowH)
        row:SetAlpha(info.online and 1 or 0.5)
        row:Show()

        local nameFs = row.nameFs
        nameFs:ClearAllPoints()
        nameFs:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
        nameFs:SetWidth(nameW)
        StyleFont(nameFs, WBLook().nameFont, nameFont)
        nameFs:SetText(StripRealm(info.name))
        local nc = ClassColor(info.class) or (info.isLocal and RC:GetColor("text", "gold") or RC:GetColor("ui", "headerText"))
        nameFs:SetTextColor(nc.r, nc.g, nc.b, 1)

        local subFs = row.subFs
        subFs:ClearAllPoints()
        subFs:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -subY)
        subFs:SetWidth(nameW)
        StyleFont(subFs, WBLook().subFont, subFont)
        local st, scol = SublineFor(info)
        subFs:SetText(st)
        subFs:SetTextColor(scol.r, scol.g, scol.b, 1)
        PlaceText(nameFs, "name", "TOPLEFT", row, "TOPLEFT", 0, -2, RowTo(row))
        PlaceText(subFs, "sub", "TOPLEFT", row, "TOPLEFT", 0, -subY, RowTo(row))

        if not noTip then AttachNameTooltip(row, info, nameW, rowH) end

        local col = 0
        for _, def in ipairs(BoardDefs()) do
            local secs  = info.buffs and info.buffs[def.key]
            local state = secs and ((info.frozen and info.frozen[def.key]) and "booned" or "active") or "missing"
            MakeCell(row, def, x0 + col * step, state, secs, iconSz, col + 1)
            col = col + 1
        end
        HideCellsFrom(row, col + 1)
        MakeCDCell(row, CHRONO_ICON, x0 + col * step, info.cd, iconSz, "Chronoboon re-use", step, info.chrono, 1, info.booned); col = col + 1
        MakeCDCell(row, HS_ICON, x0 + col * step, info.hs, iconSz, "Hearthstone", step, nil, 2); col = col + 1
        MakeCDCell(row, DMF_ICON, x0 + col * step, DmfShow(info), iconSz, DMF_CD_TIP, step, nil, 3)
    end
    RC._wbMini = { Geom = MiniGeom, NewRow = NewMiniRow, FillRow = FillMiniRow, MinWidth = MiniMinWidth }

    local miniLastSig
    local DrawMini
    local liveDraw = {}

    local function RefreshMini(allowSkip)
        if not miniFrame or not miniFrame:IsShown() or not miniContent then return end
        local WB = RC.WorldBuffs
        if not WB then return end

        local roster = (WB.GetRoster and WB:GetRoster()) or {}

        local onlineOnly = RC.db.worldBuffs and RC.db.worldBuffs.miniOnlineOnly and true or false
        local filterMode = (RC.db.worldBuffs and RC.db.worldBuffs.miniFilter) or "all"
        local shown = {}
        for _, info in ipairs(roster) do
            if FilterPass(info, filterMode, onlineOnly) then shown[#shown + 1] = info end
        end
        SortRoster(shown)
        -- The sidebar page can change the order too; keep this board's
        -- controls showing what is actually applied.
        if miniSortCtl then miniSortCtl:Sync() end

        local parts = {}
        for _, info in ipairs(shown) do
            parts[#parts + 1] = info.name or ""
            parts[#parts + 1] = info.online and "1" or "0"
            parts[#parts + 1] = info.pvp and "p" or ""
            parts[#parts + 1] = info.location or ""
            for _, def in ipairs(WB.BUFFS) do
                local secs = info.buffs and info.buffs[def.key]
                if secs then
                    parts[#parts + 1] = ((info.frozen and info.frozen[def.key]) and "b" or "a") .. FmtTime(secs)
                else
                    parts[#parts + 1] = "m"
                end
            end
            parts[#parts + 1] = "c" .. (info.cd and FmtTime(info.cd) or "")
            parts[#parts + 1] = "h" .. (info.hs and FmtTime(info.hs) or "")
            parts[#parts + 1] = "q" .. (info.chrono or "")
        end
        -- Ticker-driven refreshes (allowSkip) rebuild the row list only when
        -- the concatenated signature changes; drop-timer text still updates
        -- every tick via RefreshDrops() below.
        local sig = table.concat(parts, "|")
        if allowSkip and sig == miniLastSig then
            RefreshDrops()
            return
        end
        miniLastSig = sig

        local W = liveDraw
        W.frame, W.content, W.scroll, W.scrollBar = miniFrame, miniContent, miniScroll, miniScrollBar
        W.rows, W.userSized = miniRows, miniUserSized
        DrawMini(W, shown, #roster)

        RefreshDrops()
    end

    -- Lays the toons out in the board's scroll area and sizes it (the live
    -- board and the settings preview's sample alike). W = { frame,
    -- content, scroll, scrollBar, rows = the row pool, userSized, noTip };
    -- shown = the toons in order; total = how many report at all. (The
    -- body reads the names it always did, now taken from W.)
    function DrawMini(W, shown, total)
        local miniFrame, miniContent, miniScroll, miniScrollBar = W.frame, W.content, W.scroll, W.scrollBar
        local miniRows, miniUserSized = W.rows, W.userSized
        -- Rows are pooled by position and rewritten in place. Orphaning them
        -- with SetParent(nil) used to hand the whole row - frame, two font
        -- strings, a name hit frame and every cell's textures and hit frames
        -- - to the garbage collector on each signature change, which for a
        -- board polled every 2s meant a steady churn of frames that WoW
        -- never actually frees. Leftover rows below are hidden, not dropped.
        if miniScroll then miniContent:SetWidth(miniScroll:GetWidth()) end

        local cw = miniContent:GetWidth() or 0
        if cw < 50 then cw = ((miniFrame and miniFrame:GetWidth()) or MiniMinWidth()) - 16 end
        local fw = (miniFrame and miniFrame:GetWidth()) or MiniMinWidth()
        -- Clamp keeps icons from shrinking below their minimum or growing
        -- unbounded when the window is resized far past its natural width.
        local scale = fw / MiniMinWidth()
        if scale < 1 then scale = 1 elseif scale > 2.5 then scale = 2.5 end
        local G = MiniGeom(cw, scale)
        local rowH = G.rowH

        local rowY = 0
        for i, info in ipairs(shown) do
            local row = miniRows[i]
            if not row then
                row = NewMiniRow(miniContent)
                miniRows[i] = row
            end
            FillMiniRow(row, info, i, G, miniContent, rowY, W.noTip)
            rowY = rowY - rowH
        end

        local rows = #shown
        for i = rows + 1, #miniRows do miniRows[i]:Hide() end

        if rows == 0 then
            local empty = miniContent.emptyFs
            if not empty then
                empty = RC:CreateFontString(miniContent, "OVERLAY", nil, 10)
                empty:SetPoint("TOPLEFT", miniContent, "TOPLEFT", 0, -2)
                miniContent.emptyFs = empty
            end
            empty:SetText(total == 0 and RCL["No toons reporting."] or RCL["No toons match the filter."])
            local ec = RC:GetColor("text", "gray")
            empty:SetTextColor(ec.r, ec.g, ec.b, 1)
            empty:Show()
        elseif miniContent.emptyFs then
            miniContent.emptyFs:Hide()
        end

        local contentH = math.max(1, rows) * rowH
        miniContent:SetHeight(contentH)

        if not miniUserSized then
            local h = MINI_HEADER + MINI_CTRLH + 8 + contentH + MINI_DROPS_H + 12
            miniFrame:SetHeight(math.min(h, 820))
        end

        if miniScroll and miniScrollBar and miniScrollBar.SyncRange then
            miniScrollBar:SyncRange(contentH, miniScroll:GetHeight() or 0)
            local _, mx = miniScrollBar:GetMinMaxValues()
            if (miniScrollBar:GetValue() or 0) > mx then miniScrollBar:SetValue(mx) end
            if mx <= 0 then miniScroll:SetVerticalScroll(0) end
        end
    end

    -- A look change: restyle once, redraw the compact board now.
    function RC._wbApplyLook()
        RC._wbLookSig = RC._wbLookSig + 1
        miniLastSig = nil
        if miniFrame and not miniUserSized then miniFrame:SetWidth(MiniMinWidth()) end
        if miniFrame and RC.ApplyFrameCustom then
            RC:ApplyFrameCustom(miniFrame, function() return RC.db and RC.db.worldBuffs end, { parts = miniFrame._rcParts })
        end
        RefreshMini()
    end

    -- The board's window parts on f, in the order the board makes them:
    -- fill and ring, the title bar (mark, title, close), the filter row
    -- (filter dropdown, Online only, Level 60, the legend), the sort row,
    -- the scroll area and the footer. The live board and the settings
    -- preview's sample are the same window; a sample's controls change
    -- nothing (and RC.UI:InertSample takes their clicks away). Returns
    -- { filter, online, level, sort, scroll, content, scrollBar, footer }.
    local function BuildMiniParts(f, sample)
        -- Flat window: WHITE8X8 fill, 1px black ring, and a flat title
        -- bar with a gold hairline under it - the bar texture is for
        -- real status bars, not furniture.
        local FLAT = "Interface\\Buttons\\WHITE8X8"
        local bgTex = f:CreateTexture(nil, "BACKGROUND")
        bgTex:SetAllPoints()
        bgTex:SetTexture(FLAT)
        local wbg = RC:GetColor("ui", "windowBackground")
        bgTex:SetVertexColor(wbg.r, wbg.g, wbg.b, wbg.a or 1)
        local ring
        if RC.UI and RC.UI.CreateSimpleBorder then ring = RC.UI:CreateSimpleBorder(f) end
        f._rcParts = { bg = bgTex, border = ring }

        local headerBar = CreateFrame("Frame", nil, f)
        headerBar:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
        headerBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
        headerBar:SetHeight(MINI_HEADER)
        local hbg = headerBar:CreateTexture(nil, "BACKGROUND")
        hbg:SetAllPoints()
        hbg:SetTexture(FLAT)
        local hb = RC:GetColor("ui", "headerBackground")
        hbg:SetVertexColor(hb.r, hb.g, hb.b, hb.a or 1)
        local accentLine = headerBar:CreateTexture(nil, "ARTWORK")
        accentLine:SetPoint("BOTTOMLEFT", headerBar, "BOTTOMLEFT", 0, 0)
        accentLine:SetPoint("BOTTOMRIGHT", headerBar, "BOTTOMRIGHT", 0, 0)
        accentLine:SetHeight(1)
        accentLine:SetTexture(FLAT)
        local ag = RC:GetColor("ui", "accentGold")
        accentLine:SetVertexColor(ag.r, ag.g, ag.b, 0.6)
        -- the same header as every other Readycheck window: gradient fill,
        -- stepped rule, the sheen on opening and the living mark
        if RC.UI and RC.UI.ApplyHeaderArt then
            accentLine:Hide()
            RC.UI:ApplyHeaderArt(headerBar, { fill = hbg, stepX = 110 })
        end

        local titleIcon = RC.UI:AddTitleIcon(headerBar, 16, 8)

        local title = RC:CreateFontString(headerBar, "OVERLAY", nil, 15, "OUTLINE")
        title:SetPoint("LEFT", titleIcon, "RIGHT", 8, 0)
        title:SetText(RCL["World Buffs"])
        local tc = RC:GetColor("ui", "headerText")
        title:SetTextColor(tc.r, tc.g, tc.b, 1)

        if RC.UI and RC.UI.CreateXCloseButton then
            local xb = RC.UI:CreateXCloseButton(headerBar, 22, function() if not sample then f:Hide() end end)
            xb:SetPoint("RIGHT", headerBar, "RIGHT", -5, 0)
        end
        -- the 5.0 popup header (UIF_Dialogs); the board keeps its own look
        RC.UI:SkinPopup(f, { header = headerBar, title = title, chrome = false, scan = false })

        local controls = CreateFrame("Frame", nil, f)
        controls:SetPoint("TOPLEFT",  headerBar, "BOTTOMLEFT",  0, 0)
        controls:SetPoint("TOPRIGHT", headerBar, "BOTTOMRIGHT", 0, 0)
        controls:SetHeight(MINI_CTRLROW)

        local function curFilter() return (RC.db.worldBuffs and RC.db.worldBuffs.miniFilter) or "all" end
        local function curOnline() return RC.db.worldBuffs and RC.db.worldBuffs.miniOnlineOnly and true or false end

        local fDD = RC.UI:CreateScrollableDropdown(controls, 116, FILTER_LABELS[curFilter()] or RCL["All"], 3)
        fDD:SetPoint("LEFT", controls, "LEFT", 8, 0)
        fDD:SetHeight(22)
        fDD:SetItems({
            { text = RCL["All"],         value = "all" },
            { text = RCL["Needs buffs"], value = "needs" },
            { text = RCL["Booned"],      value = "booned" },
        }, function(value)
            if sample then return end
            if not RC.db.worldBuffs then RC.db.worldBuffs = {} end
            RC.db.worldBuffs.miniFilter = value
            RC:SaveConfigurationToProfile()
            RefreshMini()
        end)
        if fDD.SetSearchEnabled then fDD:SetSearchEnabled(false) end
        local fddMenu = fDD.menu or _G[(fDD:GetName() or "") .. "_Menu"]
        if fddMenu then fddMenu:SetFrameStrata("TOOLTIP") end

        local onlineChk = RC.UI:CreateCheckbox(controls, RCL["Online only"], curOnline())
        onlineChk.parentFrame:SetPoint("LEFT", fDD, "RIGHT", 12, 0)
        onlineChk.parentFrame:SetWidth(96)
        onlineChk:SetScript("OnClick", function(cb)
            if sample then return end
            local on = cb:GetChecked()
            RC:ForceCheckboxUpdate(cb, on)
            if not RC.db.worldBuffs then RC.db.worldBuffs = {} end
            RC.db.worldBuffs.miniOnlineOnly = on
            RC:SaveConfigurationToProfile()
            RefreshMini()
        end)

        local lvlDefault = RC.db.worldBuffs and RC.db.worldBuffs.hideBelowMax
        if lvlDefault == nil then lvlDefault = true end
        -- Toggles db.worldBuffs.hideBelowMax: only level-60 characters are
        -- listed. Kept short because this row also holds the legend at the
        -- right edge at the board's minimum width.
        local lvlChk = RC.UI:CreateCheckbox(controls, RCL["Level 60"], lvlDefault and true or false)
        lvlChk.parentFrame:SetPoint("LEFT", onlineChk.parentFrame, "RIGHT", 4, 0)
        lvlChk.parentFrame:SetWidth(72)
        lvlChk:SetScript("OnClick", function(cb)
            if sample then return end
            local on = cb:GetChecked()
            RC:ForceCheckboxUpdate(cb, on)
            if not RC.db.worldBuffs then RC.db.worldBuffs = {} end
            RC.db.worldBuffs.hideBelowMax = on
            RC:SaveConfigurationToProfile()
            RefreshMini()
        end)

        local sortRow = CreateFrame("Frame", nil, f)
        sortRow:SetPoint("TOPLEFT",  controls, "BOTTOMLEFT",  8, 0)
        sortRow:SetPoint("TOPRIGHT", controls, "BOTTOMRIGHT", -8, 0)
        sortRow:SetHeight(MINI_CTRLROW)
        local sortCtl = BuildSortControls(sortRow, function() if not sample then RefreshMini() end end,
            { menuStrata = "TOOLTIP", compact = true })

        local lMiss = RC:CreateFontString(controls, "OVERLAY", nil, 10)
        local cM = StateColor("missing");    lMiss:SetText(RCL["missing"]); lMiss:SetTextColor(cM.r, cM.g, cM.b, 1)
        lMiss:SetPoint("RIGHT", controls, "RIGHT", -8, 0)
        local lAct = RC:CreateFontString(controls, "OVERLAY", nil, 10)
        local cA = StateColor("active"); lAct:SetText(RCL["active"]);  lAct:SetTextColor(cA.r, cA.g, cA.b, 1)
        lAct:SetPoint("RIGHT", lMiss, "LEFT", -6, 0)
        local lBoon = RC:CreateFontString(controls, "OVERLAY", nil, 10)
        local cB = StateColor("booned");  lBoon:SetText(RCL["booned"]); lBoon:SetTextColor(cB.r, cB.g, cB.b, 1)
        lBoon:SetPoint("RIGHT", lAct, "LEFT", -6, 0)

        local scroll = CreateFrame("ScrollFrame", nil, f)
        scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -(MINI_HEADER + MINI_CTRLH + 4))
        scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, MINI_DROPS_H + 12)
        local scrollChild = CreateFrame("Frame", nil, scroll)
        scrollChild:SetSize(1, 1)
        scroll:SetScrollChild(scrollChild)

        local scrollBar
        if RC.UI and RC.UI.AttachScrollbar then
            scrollBar = RC.UI:AttachScrollbar(scroll, scroll, { width = MINI_SCROLLW - 4 })
        end

        local footer = CreateFrame("Frame", nil, f)
        footer:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",  8, 8)
        footer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 8)
        footer:SetHeight(MINI_DROPS_H)
        -- Section divider: black, like every rule that is not under a title.
        local fsep = footer:CreateTexture(nil, "ARTWORK")
        fsep:SetPoint("TOPLEFT",  footer, "TOPLEFT",  0, 0)
        fsep:SetPoint("TOPRIGHT", footer, "TOPRIGHT", 0, 0)
        fsep:SetHeight(1)
        fsep:SetTexture(FLAT)
        local sepCol = RC:GetColor("ui", "borderNormal")
        fsep:SetVertexColor(sepCol.r, sepCol.g, sepCol.b, sepCol.a or 1)

        return { filter = fDD, online = onlineChk, level = lvlChk, sort = sortCtl,
                 scroll = scroll, content = scrollChild, scrollBar = scrollBar, footer = footer }
    end

    -- Same six-dot handle every other Readycheck window uses, including
    -- the resize bounds (the board and its sample).
    local function AttachMiniGrip(f)
        return RC.UI:AttachResizeGrip(f, {
            minW = MiniMinWidth(), minH = 110 + MINI_CTRLH,
            maxW = 900, maxH = 820,
        })
    end

    local function CreateMini()
        if miniFrame then return miniFrame end
        local width = MiniMinWidth()

        local f = CreateFrame("Frame", "ReadycheckWorldBuffMini", UIParent)
        f:SetSize(width, MINI_HEADER + MINI_CTRLH + 8 + 7 * MiniRowH())
        f:SetFrameStrata("DIALOG")
        f:SetToplevel(true)
        f:SetClampedToScreen(true)

        local parts = BuildMiniParts(f)
        miniSortCtl = parts.sort
        miniScroll, miniContent = parts.scroll, parts.content
        miniScrollBar = parts.scrollBar
        miniFooter = parts.footer

        RC.UI:RegisterEscapeClose("ReadycheckWorldBuffMini")

        f:EnableMouse(true)
        RC.Position.Bind(f, function()
            if not RC.db.worldBuffs then RC.db.worldBuffs = {} end
            RC.db.worldBuffs.miniPos = RC.db.worldBuffs.miniPos or {}
            return RC.db.worldBuffs.miniPos
        end, { point = "TOPLEFT", xKey = "x", yKey = "y",
               legacyRel = "CENTER", legacyPoint = "CENTER",
               default = { point = "CENTER", x = 0, y = 0 } })
        RC.Position.MakeMovable(f)

        -- The handle (AttachMiniGrip); only the "remember what the user
        -- picked" half below is specific to the mini board.
        local grip = AttachMiniGrip(f)
        grip:SetScript("OnMouseUp", function()
            f:StopMovingOrSizing()
            miniUserSized = true
            if not RC.db.worldBuffs then RC.db.worldBuffs = {} end
            RC.db.worldBuffs.miniW = f:GetWidth()
            RC.db.worldBuffs.miniH = f:GetHeight()
            RC:SaveConfigurationToProfile()
            RefreshMini()
        end)

        local mw = RC.db and RC.db.worldBuffs and RC.db.worldBuffs.miniW
        local mh = RC.db and RC.db.worldBuffs and RC.db.worldBuffs.miniH
        if mw and mh then
            miniUserSized = true
            f:SetSize(math.max(mw, MiniMinWidth()), math.max(mh, 110 + MINI_CTRLH))
        end
        RC.Position.RestoreFrame(f)

        if RC.UIMover and RC.UIMover.RegisterFrame then
            RC.UIMover:RegisterFrame("worldBuffMini", f, "World Buff Mini",
                { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 })
        end

        f:Hide()
        miniFrame = f
        -- layer / fade / edge (World Buffs > Look); nothing set = as made
        if RC.ApplyFrameCustom then
            RC:ApplyFrameCustom(f, function() return RC.db and RC.db.worldBuffs end, { parts = f._rcParts })
        end
        return f
    end

    RC.EnsureWorldBuffMini = CreateMini

    -- THE SETTINGS PREVIEW'S BOARD: the same window (BuildMiniParts and
    -- the grip) on any parent, inert, and never in UIParent, UIMover, the
    -- escape list or the live board's own state.
    local function NewMiniWindowSample(parent)
        local f = CreateFrame("Frame", nil, parent)
        f:SetSize(MiniMinWidth(), MINI_HEADER + MINI_CTRLH + 8 + 3 * MiniRowH())
        f._rcSample = true
        local parts = BuildMiniParts(f, true)
        f._wbParts, f._wbGrip = parts, AttachMiniGrip(f)
        f._wbDraw = { frame = f, content = parts.content, scroll = parts.scroll,
                      scrollBar = parts.scrollBar, rows = {}, noTip = true }
        RC.UI:InertSample(f)
        return f
    end

    -- The sample as the board shows this roster and these drops: its
    -- filter, Online only, Level 60 and sort as saved, the look and the
    -- width the board opens at, at the least height the grip allows (so
    -- it reads on the strip; the toons scroll as they do in game).
    -- Returns its size.
    local function FillMiniWindowSample(f, roster, drops)
        local parts = f._wbParts
        local wb = (RC.db and RC.db.worldBuffs) or {}
        local filterMode = wb.miniFilter or "all"
        local onlineOnly = wb.miniOnlineOnly and true or false
        local lvl = wb.hideBelowMax
        if lvl == nil then lvl = true end
        if parts.filter.SetSelectedValue then parts.filter:SetSelectedValue(filterMode, FILTER_LABELS[filterMode] or RCL["All"]) end
        RC:ForceCheckboxUpdate(parts.online, onlineOnly)
        RC:ForceCheckboxUpdate(parts.level, lvl and true or false)
        parts.sort:Sync()
        local shown = {}
        for _, info in ipairs(roster) do
            if FilterPass(info, filterMode, onlineOnly) then shown[#shown + 1] = info end
        end
        SortRoster(shown)
        local w = MiniMinWidth()
        if wb.miniW and wb.miniH then w = math.max(wb.miniW, w) end
        f:SetSize(w, 110 + MINI_CTRLH)
        f._wbDraw.userSized = true
        DrawMini(f._wbDraw, shown, #roster)
        -- a row the scroll area cuts off whole is hidden, as the game clips it
        local viewH = f:GetHeight() - (MINI_HEADER + MINI_CTRLH + 4) - (MINI_DROPS_H + 12)
        for _, row in ipairs(f._wbDraw.rows) do
            if row:IsShown() and -(select(5, row:GetPoint(1)) or 0) >= viewH then row:Hide() end
        end
        FillDrops(parts.footer, drops, true)
        if RC.ApplyFrameCustom then
            RC:ApplyFrameCustom(f, function() return RC.db and RC.db.worldBuffs end, { parts = f._rcParts, sample = true })
        end
        RC.UI:InertSample(f, true)
        return f:GetWidth(), f:GetHeight()
    end
    RC._wbMini.NewWindow, RC._wbMini.FillWindow = NewMiniWindowSample, FillMiniWindowSample

    function RC:ToggleWorldBuffMini()
        local f = CreateMini()
        if f:IsShown() then
            f:Hide()
            return
        end
        f:Show()
        f:Raise()
        RefreshMini()
        -- 2s poll while the mini board is shown; skips rebuild when the
        -- mouse is over it so hover tooltips/interactions aren't disrupted.
        if not miniTicker then
            local function tk()
                if miniFrame and miniFrame:IsShown() then
                    if MouseIsOver(miniFrame) then return end
                    RefreshMini(true)
                end
            end
            if RC.Profiler and RC.Profiler.TrackTicker then
                miniTicker = RC.Profiler:TrackTicker("WorldBuffs:MiniRefresh", 2.0, tk)
            else
                miniTicker = C_Timer.NewTicker(2.0, tk)
            end
        end
    end

    local panelTicker
    local function StopPanelTicker()
        if panelTicker then
            if panelTicker.Cancel then panelTicker:Cancel() end
            panelTicker = nil
        end
    end

    -- Keeps the visible sidebar page live without a push mechanism: re-renders
    -- the whole panel every 2s (skipped while the mouse is over it) via a full
    -- ShowSidebarWorldBuffs(true) call.
    function RC._wbEnsureTicker()
        if panelTicker then return end
        local function tick()
            local outer = RC.sidebarConfigFrame
            -- Leaving the page stops the ticker outright rather than leaving
            -- it awake forever doing nothing: ShowSidebarWorldBuffs calls
            -- _wbEnsureTicker on the way back in, which spins a fresh one.
            if not outer or not outer:IsShown()
                or not RC.SidebarState or RC.SidebarState.selectedItem ~= "world_buffs" then
                StopPanelTicker()
                return
            end
            if MouseIsOver(outer) then return end
            local compat = outer.compatFrame
            if not compat then return end
            -- only the board itself is live; the look tabs hold sliders
            if (compat.wbTab or "board") ~= "board" then return end
            RC:ShowSidebarWorldBuffs(compat, true)
        end
        if RC.Profiler and RC.Profiler.TrackTicker then
            panelTicker = RC.Profiler:TrackTicker("WorldBuffs:PanelRefresh", 2.0, tick)
        else
            panelTicker = C_Timer.NewTicker(2.0, tick)
        end
    end

    RC:DebugPrint("SidebarWorldBuffs loaded", "system")
end

C_Timer.After(0.5, InitializeSidebarWorldBuffs)
