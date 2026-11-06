------------------------------------------------------------------------
-- Readycheck - World Buff Timers Map Pins
-- World map icons fed by the timer store: songflower node cooldowns in
-- Felwood, and a capital-city marker with per-layer rend/ony CDs.
-- Native canvas pins (no HereBeDragons); they scale with map zoom.
------------------------------------------------------------------------
-- World buffs are Classic Era content: TBC and Forever never run this
-- addon (Readycheck Core_Flavor).
if _G.Readycheck and _G.Readycheck.FeatureOn and not _G.Readycheck:FeatureOn("world_tools") then return end
local RC = _G.Readycheck
if not RC or not RC.WorldBuffTimers then return end
local WBT = RC.WorldBuffTimers

local GetServerTime = GetServerTime
local math_floor = math.floor

local ZONE_FELWOOD = 1448
local FLOWER_CD = WBT.FLOWER_CD or 1500 -- songflower node respawn (single source: WBT_Core)

local CAPITAL_MAPS = { [1454] = true, [1453] = true }
local RCC = RC.Compat or {}
local GetSpellInfo = GetSpellInfo or RCC.GetSpellInfo
local FLOWER_ICON  = (GetSpellInfo and select(3, GetSpellInfo(15366)))
    or "Interface\\Icons\\INV_Misc_Flower_02"

local pins = {}          -- flower pins by node index
local capitalPin
local ticker
local shownMap

-- Callers only reach this with a live countdown; an expired or absent
-- timer is nil long before it gets here and is drawn as "?" instead.
local function fmtShort(rem)
    local m = math_floor(rem / 60)
    local s = math_floor(rem % 60)
    if m >= 60 then
        return string.format("%dh%02dm", math_floor(m / 60), m % 60)
    end
    return string.format("%d:%02d", m, s)
end

-- Tooltip lines take r,g,b; the theme hands out a table.
local function rgb(name)
    local c = RC:GetColor("text", name)
    return c.r, c.g, c.b
end

local function canvas()
    return WorldMapFrame and WorldMapFrame.ScrollContainer
        and WorldMapFrame.ScrollContainer.Child
end

local function newPin(parent, iconTexture, iconSize)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(iconSize, iconSize)
    f:SetFrameStrata("HIGH")
    f.icon = f:CreateTexture(nil, "OVERLAY")
    f.icon:SetAllPoints()
    f.icon:SetTexture(iconTexture)
    -- Flat 1px black ring around the icon, drawn one sublevel above it so
    -- the stack order never depends on creation order.
    if RC.UI and RC.UI.CreateSimpleBorder then
        f.border = RC.UI:CreateSimpleBorder(f, 1, 1)
    end
    f.text = f:CreateFontString(nil, "OVERLAY")
    if RC.ApplyCustomFont then
        RC:ApplyCustomFont(f.text, 10, "OUTLINE")
    end
    f.text:SetPoint("TOP", f, "BOTTOM", 0, -1)
    f:SetMouseClickEnabled(false)
    f:EnableMouse(true)
    f:Hide()
    return f
end

-- Where Felwood sits on the map being shown, as fractions of that map:
-- the whole of it on Felwood's own map; its rectangle on Kalimdor's and
-- on the world's (the client knows); nil on a map that does not hold it.
-- So the flowers and their timers stay on the map when it is zoomed out
-- to the continent - which a stitched, free-zooming world map is most of
-- the time (2026-10-31, Zac: "on the seamless map it still needs to show
-- songflowers and timers").
local function felwoodRect(mapID)
    if mapID == ZONE_FELWOOD then return 0, 1, 0, 1 end
    if not (mapID and C_Map and C_Map.GetMapRectOnMap) then return nil end
    local ok, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, ZONE_FELWOOD, mapID)
    if ok and minX and maxX and minY and maxY and maxX > minX and maxY > minY then
        return minX, maxX, minY, maxY
    end
    return nil
end

-- THE SAME SIZE ON SCREEN AT EVERY ZOOM (2026-11-01, Zac: "these
-- songflower timers are so big"). The pins are children of the map's
-- canvas, and the canvas is scaled to zoom - so a 14px icon was 14 x the
-- zoom, and a zoomed-in or free-zooming map made them the size of a
-- zone. Each pin carries the inverse of the canvas's scale; its anchor
-- offset is in its own (now smaller) units, so it is multiplied back up.
-- Re-placed whenever the canvas's scale changes (hooked below).
local function placePin(pin, xPct, yPct, minX, maxX, minY, maxY)
    local c = canvas()
    if not c then return end
    local w, h = c:GetWidth(), c:GetHeight()
    if not w or w == 0 then return end
    minX, maxX, minY, maxY = minX or 0, maxX or 1, minY or 0, maxY or 1
    pin.at = { xPct, yPct, minX, maxX, minY, maxY }
    local fx = minX + (xPct / 100) * (maxX - minX)
    local fy = minY + (yPct / 100) * (maxY - minY)
    local cs = c:GetScale() or 1
    if cs <= 0 then cs = 1 end
    pin:SetScale(1 / cs)
    pin:ClearAllPoints()
    pin:SetPoint("CENTER", c, "TOPLEFT", fx * w * cs, -fy * h * cs)
end

local flowerRect, applyFlowerZoom   -- (defined with the flowers' zoom gate, further down)
local scaleHooked
local function hookCanvasScale()
    local c = canvas()
    if scaleHooked or not c then return end
    scaleHooked = true
    hooksecurefunc(c, "SetScale", function()
        if not flowerRect then return end
        for _, pin in pairs(pins) do
            if pin.at then placePin(pin, unpack(pin.at)) end
        end
        applyFlowerZoom()
    end)
end

-- nil means "no idea", and an EXPIRED timestamp counts as no idea. Once
-- the 25 minutes are up the node has certainly respawned, but whether it
-- is still standing depends on whether anyone has walked past and picked
-- it since - which is exactly what we have no data for. Reporting that as
-- "Ready" is a confident answer we have not earned; a stale pick from
-- three hours ago would read the same as one that just came back.
-- `times` is WBT:GetFlowerTimes() computed once by a caller that walks
-- all ten nodes (pass false for "none"); nil fetches it here, for the
-- one-off tooltip callers.
-- The /wb board's own per-node answer, as ready-at times on the board's
-- clock (time()), read at most once a second. The board and these pins
-- used to work the time out from two different stores on two different
-- clocks, so the minimap could sit 10-20s off the board; a node the
-- board has a countdown for now reads the board's number everywhere.
-- nil when the board is not loaded.
local boardAt, boardSnap
local function boardReadyAt()
    local WB2 = RC.WorldBuffs
    if not (WB2 and WB2.GetSongflowerNodes) then return nil end
    local now = time()
    if boardSnap and boardAt == now then return boardSnap end
    boardSnap, boardAt = {}, now
    local ok, nodes = pcall(WB2.GetSongflowerNodes, WB2)
    if ok and type(nodes) == "table" then
        for _, n in ipairs(nodes) do
            if n.idx and n.rem then boardSnap[n.idx] = now + n.rem end
        end
    end
    return boardSnap
end

local function flowerRemaining(idx, times)
    local board = boardReadyAt()
    local at = board and board[idx]
    if at then
        local rem = at - time()
        if rem > 0 then return rem end
    end
    if times == nil then times = WBT:GetFlowerTimes() end
    local t = times and times[idx]
    if not t or t <= 0 then return nil end
    local rem = (t + FLOWER_CD) - GetServerTime()
    if rem <= 0 then return nil end
    return rem
end

local function updateFlowerPins()
    local times = WBT:GetFlowerTimes() or false
    for key, node in pairs(WBT.songFlowers) do
        local pin = pins[node.idx]
        if pin then
            local rem = flowerRemaining(node.idx, times)
            if rem == nil then
                pin.text:SetText("|cff999999?|r")
            else
                pin.text:SetText(fmtShort(rem))
            end
        end
    end
end

-- One column per buff, each with its own icon and status: a row reads left
-- to right as rend / ony, and a buff with no data still gets a cell rather
-- than vanishing from the readout.
--
-- There is no Nefarian column. The Head of Nefarian turn-in has no
-- cooldown on Era/Anniversary, so a countdown for it would be inventing a
-- lockout that does not exist. nefTimer is still received, stored and
-- relayed for the shared NWB pool - it is only absent from the display.
local BUFF_COLS = {
    { key = "rend", field = "rendTimer", label = "Rend",
      icon = "Interface\\Icons\\spell_arcane_teleportorgrimmar" },
    { key = "ony",  field = "onyTimer",  label = "Onyxia",
      icon = "Interface\\Icons\\inv_misc_head_dragon_01" },
}

local function cdFor(col)
    if col.key == "rend" then return WBT.rendCooldown end
    return WBT.onyCooldown
end

-- "?" when we have never seen that buff drop, so an unknown timer reads as
-- unknown rather than silently vanishing.
local function statusFor(v, col)
    local t = v and tonumber(v[col.field])
    if not t or t <= 0 then return "|cff777777?|r", nil end
    local cd = cdFor(col)
    -- Past one cooldown beyond coming up, the record is stale rather than
    -- ready - report unknown instead of a permanent green "Ready".
    if WBT.IsTimestampStale and WBT.IsTimestampStale(t, cd) then
        return "|cff777777?|r", nil
    end
    local rem = (t + cd) - GetServerTime()
    if rem <= 0 then return "|cff33ff33Ready|r", 0 end
    return fmtShort(rem), rem
end

-- Rows of { label, perBuffStatus } - shared by the grid and the tooltip.
-- "Ln" is the local sort position of the layer, so it only matches another
-- player's layer numbering while both know the same set of layers.
local function capitalRows()
    local d = WBT:Data()
    if not d then return {} end
    local rows = {}
    local function rowFor(label, v)
        local cells = {}
        for i, col in ipairs(BUFF_COLS) do
            cells[i] = select(1, statusFor(v, col))
        end
        rows[#rows + 1] = { label = label, cells = cells }
    end
    if WBT:IsLayered() and next(d.layers) then
        local keys = {}
        for k in pairs(d.layers) do keys[#keys + 1] = k end
        table.sort(keys)
        for i, k in ipairs(keys) do
            rowFor("L" .. i, d.layers[k])
        end
    end
    if #rows == 0 then rowFor("", d) end
    return rows
end

local LABEL_W, CELL_W, ROW_H, ICON = 18, 72, 16, 13

local function ensureRow(container, i)
    container.rows = container.rows or {}
    local row = container.rows[i]
    if row then return row end
    row = CreateFrame("Frame", nil, container)
    row:SetSize(LABEL_W + CELL_W * #BUFF_COLS, ROW_H)
    row:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -(i - 1) * ROW_H)
    row.label = row:CreateFontString(nil, "OVERLAY")
    if RC.ApplyCustomFont then RC:ApplyCustomFont(row.label, 10, "OUTLINE") end
    row.label:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.label:SetWidth(LABEL_W)
    row.label:SetJustifyH("LEFT")
    row.cells = {}
    for c, col in ipairs(BUFF_COLS) do
        local cell = {}
        cell.icon = row:CreateTexture(nil, "OVERLAY")
        cell.icon:SetSize(ICON, ICON)
        cell.icon:SetTexture(col.icon)
        cell.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        cell.icon:SetPoint("LEFT", row, "LEFT", LABEL_W + (c - 1) * CELL_W, 0)
        cell.text = row:CreateFontString(nil, "OVERLAY")
        if RC.ApplyCustomFont then RC:ApplyCustomFont(cell.text, 10, "OUTLINE") end
        cell.text:SetPoint("LEFT", cell.icon, "RIGHT", 3, 0)
        cell.text:SetJustifyH("LEFT")
        row.cells[c] = cell
    end
    container.rows[i] = row
    return row
end

-- the capital readout drawn into a container (the pin, or a preview sample)
local function fillCapital(container, rows)
    for i, data in ipairs(rows) do
        local row = ensureRow(container, i)
        row.label:SetText(data.label ~= "" and ("|cffffd200" .. data.label .. "|r") or "")
        for c = 1, #BUFF_COLS do
            row.cells[c].text:SetText(data.cells[c])
        end
        row:Show()
    end
    if container.rows then
        for i = #rows + 1, #container.rows do container.rows[i]:Hide() end
    end
    container:SetSize(LABEL_W + CELL_W * #BUFF_COLS, math.max(#rows, 1) * ROW_H)
end

local function updateCapitalPin()
    if not (capitalPin and capitalPin:IsShown()) then return end
    fillCapital(capitalPin, capitalRows())
end

-- Samples for the settings preview, drawn by the pins' own code with fake
-- timers: a songflower pin (its icon, ring and countdown) and the capital
-- readout. Parented to the preview canvas; no map, no events, no ticker.
function WBT.NewFlowerPinSample(parent, text)
    local pin = newPin(parent, FLOWER_ICON, 14)
    pin.text:SetText(text or "12:34")
    pin:EnableMouse(false)
    pin:Show()
    return pin
end
function WBT.NewCapitalSample(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(LABEL_W + CELL_W * #BUFF_COLS, ROW_H)
    return f
end
function WBT.FillCapitalSample(container, rows) fillCapital(container, rows) end
function WBT.FlowerTimeText(rem) return rem and fmtShort(rem) or "|cff999999?|r" end

------------------------------------------------------------------------
-- THE DROPS STRIP (2026-11-01, Zac: "can we also do something like how
-- the /wb menu in readycheck does buff timers on the bottom of the
-- menu"). The /wb mini board's footer, along the bottom of the world
-- map: one slot per world buff the board tracks (RC.WorldBuffs:GetDrops,
-- the board's own numbers), its icon and its countdown, "Ready" or "?",
-- the board's tooltip lines on hover. On every map, so it no longer
-- depends on which city or zone the map shows. Replaces the corner box
-- that sat on capital maps. Ends 56px short of the right edge, clear of
-- the seamless map's tab rail.
------------------------------------------------------------------------
local strip
local STRIP_H, STRIP_ICON = 20, 14

local function fmtCD(sec)
    sec = math_floor(sec or 0)
    if sec >= 3600 then
        local h = math_floor(sec / 3600)
        local m = math_floor((sec % 3600) / 60)
        return (m > 0) and (h .. "h" .. m .. "m") or (h .. "h")
    elseif sec >= 60 then
        return math_floor(sec / 60) .. "m"
    end
    return sec .. "s"
end

-- DOCKED IN THE MAP'S BOTTOM BAR when there is one (2026-11-01, Zac:
-- "this buff stuff should be on the bottom black border of the maps
-- ui"): ZacUI's map wears a coordinate bar under the map (ZacUIMapCoords:
-- you on the left, the zone in the middle, the cursor on the right). The
-- timers go in that bar, right-aligned short of the cursor readout, with
-- no box of their own. Without that bar, a boxed strip along the bottom
-- of the map as before.
local DOCK_RIGHT = 150          -- px kept clear at the bar's right end for the cursor readout
local function ensureStrip()
    local bar = _G.ZacUIMapCoords
    if strip then
        if strip.docked ~= (bar ~= nil) then strip:Hide() strip = nil else return strip end
    end
    local viewport = WorldMapFrame and WorldMapFrame.ScrollContainer
    if not viewport then return nil end
    if bar then
        strip = CreateFrame("Frame", nil, bar)
        strip:SetAllPoints(bar)
        strip:SetFrameLevel((bar:GetFrameLevel() or 0) + 2)
        strip.docked = true
    else
        local FLAT = "Interface\\Buttons\\WHITE8X8"
        strip = CreateFrame("Frame", nil, viewport)
        strip:SetHeight(STRIP_H)
        strip:SetPoint("BOTTOMLEFT", viewport, "BOTTOMLEFT", 6, 6)
        strip:SetPoint("BOTTOMRIGHT", viewport, "BOTTOMRIGHT", -56, 6)
        strip:SetFrameStrata("HIGH")
        strip.bg = strip:CreateTexture(nil, "BACKGROUND")
        strip.bg:SetAllPoints()
        strip.bg:SetTexture(FLAT)
        local wbg = RC:GetColor("ui", "windowBackground")
        strip.bg:SetVertexColor(wbg.r, wbg.g, wbg.b, 0.85)
        if RC.UI and RC.UI.CreateSimpleBorder then RC.UI:CreateSimpleBorder(strip) end
    end
    strip.items = {}
    strip:Hide()
    return strip
end

local function stripTooltip(self)
    local d = self.drop
    if not d then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(d.label or "")
    local gray, orange, green = RC:GetColor("text", "gray"), RC:GetColor("text", "orange"), RC:GetColor("text", "green")
    if d.key == "songflower" then
        local WB2 = RC.WorldBuffs
        local nodes = (WB2 and WB2.GetSongflowerNodes and WB2:GetSongflowerNodes()) or {}
        if #nodes == 0 then
            GameTooltip:AddLine(d.known and "A node is up now." or "No data yet.", gray.r, gray.g, gray.b)
        else
            for k = 1, math.min(#nodes, 10) do
                local n = nodes[k]
                local where = n.name or (n.x and n.y and string.format("Felwood %.0f, %.0f", n.x, n.y)) or ("Node " .. tostring(n.idx))
                GameTooltip:AddLine(where .. ":  " .. fmtCD(n.rem), orange.r, orange.g, orange.b)
            end
        end
    elseif not d.known then
        GameTooltip:AddLine("No data yet.", gray.r, gray.g, gray.b)
    elseif (d.cdRemaining or 0) > 0 then
        GameTooltip:AddLine("Next: " .. fmtCD(d.cdRemaining), orange.r, orange.g, orange.b)
    else
        GameTooltip:AddLine("Available now", green.r, green.g, green.b)
    end
    GameTooltip:Show()
end

local function updateStrip()
    local WB = RC.WorldBuffs
    if not (strip and strip:IsShown() and WB and WB.GetDrops) then return end
    local ok, drops = pcall(WB.GetDrops, WB)
    if not ok or type(drops) ~= "table" then return end
    local n = #drops
    local fw = strip:GetWidth() or 0
    if fw < 40 then fw = 400 end
    local slotW = (n > 0) and (fw / n) or fw
    for i = 1, n do
        local it = strip.items[i]
        if not it then
            it = {}
            it.icon = strip:CreateTexture(nil, "ARTWORK")
            it.icon:SetSize(STRIP_ICON, STRIP_ICON)
            it.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            it.txt = strip:CreateFontString(nil, "OVERLAY")
            if RC.ApplyCustomFont then RC:ApplyCustomFont(it.txt, 10, "OUTLINE") end
            it.txt:SetJustifyH("LEFT")
            it.txt:SetWordWrap(false)
            it.hit = CreateFrame("Frame", nil, strip)
            it.hit:EnableMouse(true)
            it.hit:SetScript("OnEnter", stripTooltip)
            it.hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
            strip.items[i] = it
        end
        local d = drops[i]
        it.hit.drop = d
        local tex = d.id and GetSpellInfo and select(3, GetSpellInfo(d.id))
        it.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
        if not strip.docked then
            it.icon:ClearAllPoints()
            it.icon:SetPoint("LEFT", strip, "LEFT", (i - 1) * slotW + 5, 0)
            it.txt:ClearAllPoints()
            it.txt:SetPoint("LEFT", it.icon, "RIGHT", 4, 0)
            it.txt:SetWidth(math.max(10, slotW - STRIP_ICON - 10))
            it.hit:ClearAllPoints()
            it.hit:SetPoint("LEFT", it.icon, "LEFT", 0, 0)
            it.hit:SetSize(math.max(16, slotW - 6), STRIP_H)
        end
        local str, col
        if not d.known then
            str, col = "?", RC:GetColor("text", "gray")
            it.icon:SetDesaturated(true)
        elseif (d.cdRemaining or 0) > 0 then
            str, col = fmtCD(d.cdRemaining), RC:GetColor("text", "orange")
            it.icon:SetDesaturated(false)
        else
            str, col = "Ready", RC:GetColor("text", "green")
            it.icon:SetDesaturated(false)
        end
        it.txt:SetText(str)
        it.txt:SetTextColor(col.r, col.g, col.b, 1)
        it.icon:Show(); it.txt:Show(); it.hit:Show()
    end
    for i = n + 1, #strip.items do
        local it = strip.items[i]
        it.icon:Hide(); it.txt:Hide(); it.hit:Hide()
    end
    -- docked: laid right to left from short of the cursor readout, each as wide as its text;
    -- one that would run into the zone label (the bar's .zone, on its left) is left off rather
    -- than drawn over it, so a narrow map shows fewer timers, never a pile
    if strip.docked then
        local bar = strip:GetParent()
        local zone = bar and bar.zone
        local barLeft, barRight = strip:GetLeft(), strip:GetRight()
        local limit                                  -- px from the bar's right edge the timers may reach
        if zone and barRight and zone:GetText() and zone:GetText() ~= "" then
            local zl = zone:GetLeft()
            if zl then limit = barRight - (zl + (zone:GetStringWidth() or 0) + 12) end
        end
        if not limit and barLeft and barRight then limit = barRight - barLeft - 150 end
        local x = DOCK_RIGHT
        for i = n, 1, -1 do
            local it = strip.items[i]
            it.txt:SetWidth(0)
            local tw = math.ceil(it.txt:GetStringWidth() or 20)
            local w = STRIP_ICON + 3 + tw
            if limit and x + w > limit then
                it.icon:Hide(); it.txt:Hide(); it.hit:Hide()
            else
                it.txt:ClearAllPoints()
                it.txt:SetPoint("RIGHT", strip, "RIGHT", -x, 0)
                it.icon:ClearAllPoints()
                it.icon:SetPoint("RIGHT", it.txt, "LEFT", -3, 0)
                it.hit:ClearAllPoints()
                it.hit:SetPoint("LEFT", it.icon, "LEFT", 0, 0)
                it.hit:SetSize(w, STRIP_H)
            end
            x = x + w + 14
        end
    end
end

-- THE FLOWERS ONLY WHEN FELWOOD IS BIG ENOUGH TO READ (2026-11-01, Zac:
-- "can we hide buff timers when fully zoomed out for songflowers"). Ten
-- icons and ten countdowns on a Felwood a few dozen pixels wide are a
-- smudge; under FLOWER_MIN_PX of Felwood across on screen, they hide.
local FLOWER_MIN_PX = 220
-- (flowerRect: Felwood on the map shown, { minX, maxX, minY, maxY }, or nil)
local function flowersReadable()
    local c = canvas()
    if not (c and flowerRect) then return false end
    local w = c:GetWidth() or 0
    local cs = c:GetScale() or 1
    return (flowerRect[2] - flowerRect[1]) * w * cs >= FLOWER_MIN_PX
end
applyFlowerZoom = function()
    local on = flowersReadable()
    for _, pin in pairs(pins) do
        if pin.at then pin:SetShown(on) end
    end
end

local function stopTicker()
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
end

-- 1s ticker, and it cancels itself as soon as the map is closed: nothing
-- here may run while the world map is not on screen.
local function startTicker()
    if ticker then return end
    ticker = WBT.StartTicker("WorldBuffTimers:MapPins", 1, function()
        if not (WorldMapFrame and WorldMapFrame:IsShown()) then
            stopTicker()
            return
        end
        if flowerRect then updateFlowerPins() end   -- (Felwood's own map, or a map that holds it)
        updateStrip()
    end)
end

local function hideAll()
    for _, p in pairs(pins) do p:Hide() end
    if capitalPin then capitalPin:Hide() end
    if strip then strip:Hide() end
    shownMap, flowerRect = nil, nil
    stopTicker()
end

local function refresh()
    if not WBT:Settings().mapPins or not WBT:Settings().enabled then
        hideAll()
        return
    end
    local c = canvas()
    if not c or not WorldMapFrame:IsShown() then
        hideAll()
        return
    end
    hookCanvasScale()
    -- the buff timers along the bottom, on every map
    if capitalPin then capitalPin:Hide() end
    if ensureStrip() then
        strip:Show()
        updateStrip()
    end
    local mapID = WorldMapFrame:GetMapID()
    shownMap = mapID
    local fMinX, fMaxX, fMinY, fMaxY = felwoodRect(mapID)
    if fMinX then
        flowerRect = { fMinX, fMaxX, fMinY, fMaxY }
        for key, node in pairs(WBT.songFlowers) do
            local pin = pins[node.idx]
            if not pin then
                pin = newPin(c, FLOWER_ICON, 14)
                pin.nodeIdx = node.idx
                pin:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Songflower node " .. self.nodeIdx)
                    local rem = flowerRemaining(self.nodeIdx)
                    if rem == nil then
                        GameTooltip:AddLine("No current timer", rgb("gray"))
                    else
                        GameTooltip:AddLine("Respawns in " .. fmtShort(rem), rgb("gold"))
                    end
                    GameTooltip:Show()
                end)
                pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
                pins[node.idx] = pin
            end
            placePin(pin, node.x, node.y, fMinX, fMaxX, fMinY, fMaxY)
        end
        applyFlowerZoom()
        updateFlowerPins()
    else
        flowerRect = nil
        for _, p in pairs(pins) do p:Hide() end
    end
    startTicker()
end
WBT.RefreshMapPins = refresh

------------------------------------------------------------------------
-- Minimap pins
-- Zone size is measured once from the world-position API rather than a
-- hardcoded table, so the yard math is exact. Only ever active while
-- standing in Felwood; the ticker cancels itself everywhere else.
------------------------------------------------------------------------
local FELWOOD_FALLBACK_H, FELWOOD_FALLBACK_W = 5424.99, 3616.66

-- Minimap width in yards per zoom step (Blizzard's fixed ladder).
local MINIMAP_YARDS = {
    indoor  = { 300, 240, 180, 120, 80, 50 },
    outdoor = { 466 + 2/3, 400, 333 + 1/3, 266 + 2/3, 200, 133 + 1/3 },
}

local mmPins = {}
local mmTicker
local zoneH, zoneW

local function zoneSize()
    if zoneH then return zoneH, zoneW end
    if C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D then
        local okTL, _, tl = pcall(C_Map.GetWorldPosFromMapPos, ZONE_FELWOOD, CreateVector2D(0, 0))
        local okBR, _, br = pcall(C_Map.GetWorldPosFromMapPos, ZONE_FELWOOD, CreateVector2D(1, 1))
        if okTL and okBR and tl and br then
            local h, w = tl.x - br.x, tl.y - br.y
            if h and w and h > 0 and w > 0 then
                zoneH, zoneW = h, w
                return zoneH, zoneW
            end
        end
    end
    zoneH, zoneW = FELWOOD_FALLBACK_H, FELWOOD_FALLBACK_W
    return zoneH, zoneW
end

local function newMinimapPin(idx)
    local f = CreateFrame("Frame", nil, Minimap)
    f:SetSize(12, 12)
    f:SetFrameStrata("MEDIUM")
    f:SetFrameLevel((Minimap:GetFrameLevel() or 0) + 5)
    f.icon = f:CreateTexture(nil, "OVERLAY")
    f.icon:SetAllPoints()
    f.icon:SetTexture(FLOWER_ICON)
    f.text = f:CreateFontString(nil, "OVERLAY")
    if RC.ApplyCustomFont then
        RC:ApplyCustomFont(f.text, 9, "OUTLINE")
    end
    f.text:SetPoint("TOP", f, "BOTTOM", 0, -1)
    f.nodeIdx = idx
    f:EnableMouse(true)
    f:SetMouseClickEnabled(false)
    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Songflower node " .. self.nodeIdx)
        local rem = flowerRemaining(self.nodeIdx)
        if rem == nil then
            GameTooltip:AddLine("No current timer", rgb("gray"))
        else
            GameTooltip:AddLine("Respawns in " .. fmtShort(rem), rgb("gold"))
        end
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f:Hide()
    return f
end

local function hideMinimapPins()
    for _, p in pairs(mmPins) do p:Hide() end
end

local function updateMinimapPins()
    local s = WBT:Settings()
    if not s.enabled or s.minimapPins == false then
        hideMinimapPins()
        return false
    end
    if not C_Map or not C_Map.GetBestMapForUnit then return false end
    if C_Map.GetBestMapForUnit("player") ~= ZONE_FELWOOD then
        hideMinimapPins()
        return false
    end
    local pos = C_Map.GetPlayerMapPosition(ZONE_FELWOOD, "player")
    if not pos then
        hideMinimapPins()
        return true
    end
    local px, py = pos:GetXY()
    if not px then
        hideMinimapPins()
        return true
    end

    local h, w = zoneSize()
    local zoom = Minimap:GetZoom() or 0
    local band = (IsIndoors and IsIndoors()) and "indoor" or "outdoor"
    local across = MINIMAP_YARDS[band][zoom + 1] or MINIMAP_YARDS.outdoor[1]
    local radiusYards = across / 2
    local halfPix = (Minimap:GetWidth() or 140) / 2
    local pixPerYard = halfPix / radiusYards

    local rotate = (GetCVar and GetCVar("rotateMinimap") == "1")
    local sinF, cosF
    if rotate and GetPlayerFacing then
        local facing = GetPlayerFacing() or 0
        sinF, cosF = math.sin(facing), math.cos(facing)
    end

    local times = WBT:GetFlowerTimes() or false
    for _, node in pairs(WBT.songFlowers) do
        local idx = node.idx
        local pin = mmPins[idx]
        local rem = flowerRemaining(idx, times)

        -- A node with no live timer still gets its pin, labelled "?".
        -- Hiding it was worse than useless: an unknown node and a node
        -- that does not exist looked identical, so the map went blank
        -- exactly when you most wanted to know where to walk. "?" says
        -- "here, but nobody has reported it" - which is the honest
        -- answer, and the same one the world map pins already give.
        --
        -- Deliberately NOT "Ready": an expired pick has certainly
        -- respawned, but whether it is still standing depends on whether
        -- anyone has walked past since, and that is precisely what we
        -- have no data for. See flowerRemaining above.
        if not pin then
            pin = newMinimapPin(idx)
            mmPins[idx] = pin
        end

        -- Node and player are both map fractions; convert the delta to
        -- yards, then to screen offsets (right = east, up = north).
        local east  = (node.x / 100 - px) * w
        local north = -(node.y / 100 - py) * h
        if sinF then
            east, north = east * cosF + north * sinF, -east * sinF + north * cosF
        end
        local dx, dy = east * pixPerYard, north * pixPerYard
        local dist = math.sqrt(dx * dx + dy * dy)
        local onScreen = dist <= (halfPix - 6)
        if not onScreen and dist > 0 then
            local scale = (halfPix - 6) / dist
            dx, dy = dx * scale, dy * scale
        end
        pin:ClearAllPoints()
        pin:SetPoint("CENTER", Minimap, "CENTER", dx, dy)
        -- Unknown nodes sit back a little so a node you have a real
        -- countdown for still reads as the brighter one.
        local known = (rem ~= nil)
        pin.icon:SetAlpha(onScreen and (known and 1 or 0.7) or (known and 0.55 or 0.4))
        if onScreen then
            pin.text:SetText(known and fmtShort(rem) or "|cff999999?|r")
            pin.text:Show()
        else
            pin.text:Hide()
        end
        pin:Show()
    end
    return true
end
local function stopMinimapTicker()
    if mmTicker then
        mmTicker:Cancel()
        mmTicker = nil
    end
end

-- 0.2s ticker, like the world-map one above: it only runs while the pins
-- are live in Felwood and cancels itself the moment updateMinimapPins
-- reports nothing to draw (setting off, or the player left the zone).
local function startMinimapTicker()
    if mmTicker then return end
    mmTicker = WBT.StartTicker("WorldBuffTimers:MinimapPins", 0.2, function()
        if not updateMinimapPins() then
            stopMinimapTicker()
        end
    end)
end

-- One pass now, then keep the ticker running only if that pass had
-- something to show (the settings checkbox and Start both come through
-- here, so a toggle takes effect without a zone change).
local function refreshMinimapPins()
    if updateMinimapPins() then
        startMinimapTicker()
    else
        stopMinimapTicker()
    end
end
WBT.RefreshMinimapPins = refreshMinimapPins

local zoneWatch = CreateFrame("Frame")
zoneWatch:RegisterEvent("ZONE_CHANGED_NEW_AREA")
zoneWatch:RegisterEvent("PLAYER_ENTERING_WORLD")
zoneWatch:SetScript("OnEvent", function()
    if not WBT:Settings().enabled then return end
    if C_Map and C_Map.GetBestMapForUnit
            and C_Map.GetBestMapForUnit("player") == ZONE_FELWOOD then
        startMinimapTicker()
    else
        -- Leaving Felwood: stop the ticker entirely rather than idling.
        stopMinimapTicker()
        hideMinimapPins()
    end
end)

local hooked
local function hookMap()
    if hooked or not WorldMapFrame then return end
    hooked = true
    WorldMapFrame:HookScript("OnShow", refresh)
    WorldMapFrame:HookScript("OnHide", hideAll)
    if WorldMapFrame.OnMapChanged then
        hooksecurefunc(WorldMapFrame, "OnMapChanged", refresh)
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    C_Timer.After(3, function()
        if WBT:Settings().enabled then
            hookMap()
        end
    end)
end)

-- Live on/off, driven by WBT:ApplyEnabledState. Every draw path in this
-- file already checks Settings().enabled, so Stop only has to clear what
-- is currently on screen; the map hooks stay installed once made, since
-- WorldMapFrame has no unhook and refresh() no-ops while disabled.
WBT.MapPins = WBT.MapPins or {}

function WBT.MapPins:Start()
    hookMap()
    refresh()
    refreshMinimapPins()
end

function WBT.MapPins:Stop()
    hideAll()
    hideMinimapPins()
    stopMinimapTicker()
end
