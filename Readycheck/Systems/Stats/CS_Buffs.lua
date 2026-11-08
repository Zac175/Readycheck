------------------------------------------------------------------------
-- Readycheck - Character Stats: Buff Tracking and Pushoff Alerts
-- Shows the buff cap counter (RC.BuffCap, CS_BuffCap.lua) on the bar,
-- owns the durability/gold tooltips, and the "buff pushed off" alert
-- popup with its death/resurrection/zone-change grace periods.
-- Depends on CS (RC.CharacterStats) and STAT_DEFS from CS_Defs.lua, and
-- on RC.raidConsumables being loaded for consumable name lookups.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetSpellTexture = GetSpellTexture or (RCC and RCC.Compat and RCC.Compat.GetSpellTexture)
local AddonName = "Readycheck"

local pairs, ipairs, tostring = pairs, ipairs, tostring
local math_floor, math_max, math_min = math.floor, math.max, math.min
local string_format = string.format
local GetTime = GetTime
local CreateFrame = CreateFrame
local C_Timer = C_Timer

local RC = _G[AddonName]
if not RC then
    error("Readycheck addon not found!")
    return
end

RC._css = RC._css or {}
local _css = RC._css
local CS = RC.CharacterStats
local DURABILITY_SLOTS, DURABILITY_SLOT_NAMES, GetStatLabelColor, GetStatValueColor, STAT_DEFS =
      _css.DURABILITY_SLOTS, _css.DURABILITY_SLOT_NAMES, _css.GetStatLabelColor, _css.GetStatValueColor, _css.STAT_DEFS
-- Exact-string match against the buff tooltip name; must stay in sync with
-- in-game spelling (including the apostrophe forms) or these buffs will be
-- miscounted as pushable.
local WORLD_BUFF_NAMES = {
    ["Songflower Serenade"]              = true,
    ["Rallying Cry of the Dragonslayer"] = true,
    ["Warchief's Blessing"]              = true,
    ["Spirit of Zandalar"]               = true,
    ["Fengus's Ferocity"]                = true,
    ["Mol'dar's Moxie"]                  = true,
    ["Slip'kik's Savvy"]                 = true,
    ["Kreeg's Midsummer Mug"]            = true,
}

local function IsWorldBuff(name)
    if not name then return false end
    if WORLD_BUFF_NAMES[name] then return true end
    if name:find("Sayge's Dark Fortune", 1, true) then return true end
    return false
end

function CS:UpdateBarStats()
    if not self.barFrame or not self.barFrame:IsShown() then
        return
    end

    if RC.Profiler then RC.Profiler:StartTiming("CharStats") end

    local cache = self.statCache
    -- true once a value has outgrown the room its cell reserved for it:
    -- the only reason to lay the bar out again (CS:PaintBarStat)
    local grew = false

    if self.barStatTexts.buffs then
        if self:PaintBuffCapCell() then grew = true end
    end

    for _, key in ipairs(self.barStatOrder) do
        if key ~= "buffs" then
            local def = STAT_DEFS[key]
            local text = self.barStatTexts[key]
            if def and text then
                -- WoW Forever can hand your own stats back hidden (secret
                -- values: no maths on them): the cell keeps its last reading
                local value, hidden
                if _G.READYCHECK_IS_FOREVER then
                    local got, v = pcall(def.get, self)
                    hidden = not got or RC.Hidden(v)
                    value = (not hidden and v) or 0
                else
                    value = def.get(self) or 0
                end
                -- Round percent-based stats to one decimal before comparing to cache;
                -- avoids redundant text/color churn from float noise between reads.
                local bucketKey
                if key == "hit" or key == "crit" or key == "spellcrit" or key == "rcrit"
                   or key == "durability" then
                    bucketKey = math_floor(value * 10)
                elseif key == "fps" or key == "ms" then
                    -- whole numbers, the same as the live clock stores, so
                    -- the two never see each other's value as a change
                    value = math_floor(value + 0.5)
                    bucketKey = value
                else
                    bucketKey = value
                end

                if not hidden and bucketKey ~= cache[key] then
                    cache[key] = bucketKey
                    if self:PaintBarStat(key, value, def.fmt(value)) then grew = true end
                end
            end
        end
    end

    if grew then
        self:LayoutBarStats()
    end

    if RC.Profiler then RC.Profiler:StopTiming("CharStats") end
end

function CS:CreateHeader(text, yOffset)
    local header = RC:CreateFontString(self.panelFrame.scrollChild, "OVERLAY", nil, 9)
    header:SetPoint("TOPLEFT", 5, yOffset)
    header:SetText(text)
    local headerCol = RC:GetColor("consumables", "categoryHeader")
    header:SetTextColor(headerCol.r, headerCol.g, headerCol.b, 1)
    header:Show()

    local line = self.panelFrame.scrollChild:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("LEFT", header, "RIGHT", 6, 0)
    line:SetPoint("RIGHT", self.panelFrame.scrollChild, "RIGHT", -5, 0)
    line:SetColorTexture(headerCol.r, headerCol.g, headerCol.b, 0.3)

    table.insert(self.statLines, header)
    table.insert(self.statLines, line)
    return yOffset - 20
end

function CS:CreateStat(label, value, yOffset)
    local line = RC:CreateFontString(self.panelFrame.scrollChild, "OVERLAY", nil, 11)
    line:SetPoint("TOPLEFT", 10, yOffset)
    local labelCol = GetStatLabelColor()
    local valueCol = GetStatValueColor()
    local labelHex = string.format("|cff%02x%02x%02x", math.floor(labelCol.r*255), math.floor(labelCol.g*255), math.floor(labelCol.b*255))
    local valueHex = string.format("|cff%02x%02x%02x", math.floor(valueCol.r*255), math.floor(valueCol.g*255), math.floor(valueCol.b*255))
    line:SetText(labelHex .. label .. ": |r" .. valueHex .. value .. "|r")
    line:Show()

    table.insert(self.statLines, line)
    return yOffset - 16
end

-- Slots in use: the buffs you can see plus the hidden ones (the name
-- is older than the counter; every class uses it).
function CS:CountWarriorBuffs()
    local BC = RC.BuffCap
    if BC then return BC:Current().used end
    return #RC.Auras:Buffs()
end

-- The buff a new one would push off next: the oldest that is not a
-- world buff (those are never the ones to go).
local function NextToGo(list)
    for _, a in ipairs(list) do
        if not ((a.e and a.e.cat == "world") or IsWorldBuff(a.name)) then return a end
    end
    return nil
end

-- The Buffs cell and its pushoff icon. Returns true when the text
-- outgrew its cell. Runs from the bar's own refresh and every time the
-- counter refreshes (a stance change or Defensive State is no aura
-- event, so the bar would not hear of it otherwise).
function CS:PaintBuffCapCell(st)
    if not (self.barStatTexts and self.barStatTexts.buffs) then return false end
    local BC = RC.BuffCap
    if not BC then return false end
    st = st or BC:Current()
    local cache = self.statCache
    local free = math_max(0, st.free or 0)
    local mode = BC:Setting("barText")
    local text
    if mode == "ratio" then
        text = st.visible .. "/" .. (st.cap or "?")
    elseif mode == "free" then
        text = st.free and tostring(free) or "?"
    else
        text = tostring(st.used)
    end
    -- coloured by how full the REAL cap is, whatever the text says (a
    -- version's limit still being measured stays uncoloured; the colour
    -- scale runs 0-32)
    local fill = 0
    if BC.CAP and st.free then
        fill = BC.CAP - free
        if BC.CAP ~= 32 then fill = fill * 32 / BC.CAP end
    end
    local sig = text .. ":" .. fill
    local grew = false
    if sig ~= cache.buffs then
        cache.buffs = sig
        grew = self:PaintBarStat("buffs", fill, text) and true or false
    end

    local iconFrame = self.buffsPushoffIcon
    if iconFrame then
        if RC.db.statsBarShowPushoffIcon ~= false then
            local nxt = NextToGo(BC:List())
            if nxt and nxt.icon then
                if nxt.icon ~= cache.pushoffIcon then
                    cache.pushoffIcon = nxt.icon
                    iconFrame.texture:SetTexture(nxt.icon)
                end
                iconFrame:Show()
            else
                cache.pushoffIcon = nil
                iconFrame:Hide()
            end
        else
            iconFrame:Hide()
        end
    end
    return grew
end

local function Ago(sec)
    if sec < 60 then return RCL["just now"] end
    if sec < 3600 then return string_format(RCL["%dm ago"], math_floor(sec / 60)) end
    return string_format(RCL["%dh ago"], math_floor(sec / 3600))
end

-- The counter's breakdown, for the Buffs cell's tooltip and the icon's.
function CS:AddBuffCapLines(tip)
    local BC = RC.BuffCap
    if not BC then return end
    local st = BC:Current()
    local norm = RC:GetColor("text", "normal")
    local gray = RC:GetColor("text", "gray")
    local red = RC:GetColor("text", "red")
    local orange = RC:GetColor("text", "orange")
    local free = math_max(0, st.free)
    local hid = st.hidden + st.reserved

    tip:AddDoubleLine(RCL["Buffs on you"], tostring(st.visible), norm.r, norm.g, norm.b, norm.r, norm.g, norm.b)
    tip:AddDoubleLine(RCL["Hidden slots"], tostring(hid), norm.r, norm.g, norm.b, norm.r, norm.g, norm.b)
    for _, h in ipairs(BC:HiddenLines()) do
        local label = h.label
        if h.src == "reserved" then label = label .. RCL[" (kept free)"] end
        tip:AddLine("   " .. label, gray.r, gray.g, gray.b)
    end
    if st.learned < 0 then
        tip:AddLine(string_format(RCL["   %d fewer hidden than expected"], -st.learned), gray.r, gray.g, gray.b)
    end
    local fc = norm
    if free <= 0 then fc = red elseif free <= 1 then fc = orange end
    tip:AddDoubleLine(string_format(RCL["Real cap %d, free"], st.cap), tostring(free),
        norm.r, norm.g, norm.b, fc.r, fc.g, fc.b)
    if free <= 0 then
        tip:AddLine(RCL["AT CAP - the next buff will push one off!"], red.r, red.g, red.b)
    end

    -- the last three push-offs; the full list is on the Buff Pushoff page
    local pushes = BC:Pushes()
    if pushes[1] then
        tip:AddLine(RCL["Pushed off lately:"], red.r, red.g, red.b)
        for i = 1, math.min(3, #pushes) do
            local p = pushes[i]
            local text = "   " .. (p.n or "?")
            if p.by and #p.by > 0 then text = text .. RCL[" by "] .. table.concat(p.by, ", ") end
            if p.t then text = text .. ", " .. Ago(time() - p.t) end
            tip:AddLine(text, gray.r, gray.g, gray.b)
        end
    end

    local rem = BC:Remover()
    if rem then
        local gone = 0
        if rem.State then
            for _, a in ipairs(BC:List()) do
                local ok, s = pcall(rem.State, a)
                if ok and s == "r" then gone = gone + 1 end
            end
        end
        if gone > 0 then
            tip:AddLine(string_format(RCL["To remove: %d"], gone), orange.r, orange.g, orange.b)
        end
        if rem.Paused then
            local okp, paused = pcall(rem.Paused)
            if okp and paused then
                tip:AddLine(RCL["Buff removal is paused."], red.r, red.g, red.b)
            end
        end
    end
end

-- The pushoff icon's tooltip: the order buffs would go in.
function CS:ShowBuffPushoffTooltip(anchorFrame)
    local BC = RC.BuffCap
    GameTooltip:SetOwner(anchorFrame, "ANCHOR_BOTTOM")
    GameTooltip:SetText(RCL["Buff Pushoff Order"], 1, 0.82, 0)
    self:AddBuffCapLines(GameTooltip)
    GameTooltip:AddLine(" ", 1, 1, 1)

    local pushable = {}
    for _, a in ipairs(BC and BC:List() or {}) do
        if not ((a.e and a.e.cat == "world") or IsWorldBuff(a.name)) then
            pushable[#pushable + 1] = a
        end
    end

    local now = GetTime()
    for i = 1, math_min(5, #pushable) do
        local entry = pushable[i]
        local timeStr = ""
        if entry.exp and entry.exp > 0 then
            local remaining = entry.exp - now
            if remaining > 3600 then
                timeStr = string_format(" (%.0fh)", remaining / 3600)
            elseif remaining > 60 then
                timeStr = string_format(" (%.0fm)", remaining / 60)
            else
                timeStr = string_format(" (%.0fs)", remaining)
            end
        end
        if i == 1 then
            GameTooltip:AddLine(i .. ". " .. entry.name .. timeStr, 1, 0.4, 0.4)
        else
            GameTooltip:AddLine(i .. ". " .. entry.name .. timeStr, 0.8, 0.8, 0.8)
        end
    end

    if #pushable == 0 then
        GameTooltip:AddLine(RCL["No pushable buffs active"], 0.5, 0.5, 0.5)
    elseif #pushable > 5 then
        GameTooltip:AddLine("... +" .. (#pushable - 5) .. RCL[" more"], 0.5, 0.5, 0.5)
    end

    GameTooltip:Show()
end

function CS:ShowDurabilityTooltip(anchorFrame)
    GameTooltip:SetOwner(anchorFrame, "ANCHOR_BOTTOM")
    GameTooltip:SetText(RCL["Durability"], 1, 0.82, 0)

    local items = {}
    local totalCur, totalMax = 0, 0
    for _, slot in ipairs(DURABILITY_SLOTS) do
        local cur, max = GetInventoryItemDurability(slot)
        if max and max > 0 then
            totalCur = totalCur + cur
            totalMax = totalMax + max
            local pct = (cur / max) * 100
            local link = GetInventoryItemLink("player", slot)
            local name = DURABILITY_SLOT_NAMES[slot] or ("Slot " .. slot)
            if link then
                local n = GetItemInfo(link)
                if n then name = n end
            end
            items[#items + 1] = { name = name, pct = pct }
        end
    end

    table.sort(items, function(a, b) return a.pct < b.pct end)

    if #items == 0 then
        GameTooltip:AddLine(RCL["No durability-bearing gear equipped"], 0.6, 0.6, 0.6)
        GameTooltip:Show()
        return
    end

    local overall = (totalMax > 0) and (totalCur / totalMax) * 100 or 100
    GameTooltip:AddLine(string_format("Overall: %.0f%%", overall), 1, 1, 1)
    GameTooltip:AddLine(" ", 1, 1, 1)

    for _, it in ipairs(items) do
        local c = self:GetStatColor("durability", it.pct)
        GameTooltip:AddDoubleLine(it.name, string_format("%.0f%%", it.pct),
            0.9, 0.9, 0.9, c.r, c.g, c.b)
    end

    GameTooltip:Show()
end

-- Exact-string buff name matches below must track live tooltip text exactly.
function CS:GetDamageBonus()
    local damagePercent = 100
    if RC.Auras:BuffNamed("Sayge's Dark Fortune of Damage") then damagePercent = damagePercent + 10 end
    if RC.Auras:BuffNamed("Traces of Silithyst") then damagePercent = damagePercent + 5 end
    return damagePercent
end

function CS:GetMeleeHit()
    local hitMod = GetHitModifier()
    if not hitMod then
        hitMod = 0
    end
    return hitMod
end

function CS:GetTotalHit()
    local hitPercent = self:GetMeleeHit()
    return hitPercent
end

function CS:GetMissChance(levelDiff)
    local baseMiss = 5 + (levelDiff * 0.5)

    local _, offSpeed = UnitAttackSpeed("player")
    if offSpeed then
        baseMiss = baseMiss + 19
    end

    local totalHit = self:GetTotalHit()
    if RC.Hidden(totalHit) then return nil end   -- (hidden on WoW Forever: no reading)
    local missChance = baseMiss - totalHit

    if missChance < 0 then
        missChance = 0
    elseif missChance > 100 then
        missChance = 100
    end

    return missChance
end

function CS:GetDefenseSkill()
    if not UnitDefense then return 0 end   -- (not on every client)
    local base, modifier = UnitDefense("player")
    if RC.Hidden(base, modifier) then return nil end   -- (hidden on WoW Forever)
    return (base or 0) + (modifier or 0)
end

function CS:BuildConsumableBuffLookup()
    if self.consumableBuffLookup then return self.consumableBuffLookup end

    -- Cross-file dependency: RC.raidConsumables (consumables module) must be
    -- loaded first. Do NOT cache while it's missing - storing the empty table
    -- would make the guard above short-circuit forever, so return a throwaway
    -- empty lookup and let a later call build the real one.
    if not RC.raidConsumables then
        RC:DebugPrint("BuffPushoffAlert: raidConsumables not loaded yet", "charstats")
        return {}
    end

    local lookup = {}
    for categoryKey, category in pairs(RC.raidConsumables) do
        if category.items then
            for itemId, itemData in pairs(category.items) do
                if itemData.buffId then
                    lookup[itemData.buffId] = {
                        name = itemData.name,
                        itemId = itemId,
                        category = categoryKey
                    }
                end
            end
        end
    end
    self.consumableBuffLookup = lookup

    local count = 0
    for _ in pairs(self.consumableBuffLookup) do count = count + 1 end
    RC:DebugPrint("BuffPushoffAlert: Built lookup with " .. count .. " consumable buffs", "charstats")

    return self.consumableBuffLookup
end

-- The alert's chrome, shared by the live alert and the settings
-- preview: a flat fill, a 1px ring in the alert's own colour keys, and
-- the row pool LayoutPushoffAlert fills.
function CS:NewPushoffAlertFrame(parent, name)
    local frame = CreateFrame("Frame", name, parent)
    frame:SetSize(300, 60)
    local settings = (RC.db and RC.db.buffPushoffAlert) or {}
    local iconSize = settings.iconSize or 32
    local fontSize = settings.fontSize or 18

    local bgColor = RC:GetColor("buffPushoffAlert", "background")
    frame.bg = frame:CreateTexture(nil, "BACKGROUND")
    frame.bg:SetAllPoints()
    frame.bg:SetTexture((RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8")
    frame.bg:SetVertexColor(bgColor.r, bgColor.g, bgColor.b, bgColor.a or 0.8)

    local borderColor = RC:GetColor("buffPushoffAlert", "border")
    if RC.UI and RC.UI.CreateSimpleBorder then
        frame.border = RC.UI:CreateSimpleBorder(frame, 1)
        if frame.border then
            RC.UI:UpdateBorderColor(frame.border, borderColor, borderColor.a or 1)
        end
    end

    local showBg = settings.showBackground ~= false
    frame.bg:SetShown(showBg)
    if frame.border then
        frame.border.top:SetShown(showBg)
        frame.border.bottom:SetShown(showBg)
        frame.border.left:SetShown(showBg)
        frame.border.right:SetShown(showBg)
    end

    -- the single-line pieces older callers still restyle
    frame.icon = frame:CreateTexture(nil, "ARTWORK")
    frame.icon:SetSize(iconSize, iconSize)
    frame.icon:SetPoint("LEFT", frame, "LEFT", 10, 0)
    frame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    frame.text = RC:CreateFontString(frame, "OVERLAY", nil, fontSize)
    frame.text:SetPoint("LEFT", frame.icon, "RIGHT", 10, 0)
    frame.text:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
    frame.text:SetJustifyH("LEFT")
    local textColor = RC:GetColor("buffPushoffAlert", "text")
    frame.text:SetTextColor(textColor.r, textColor.g, textColor.b, textColor.a or 1)
    frame.text:SetShadowOffset(1, -1)
    frame.text:SetShadowColor(0, 0, 0, 1)
    frame.rows = {}
    return frame
end

-- The settings page's look table (buffPushoffAlert.look); nil fields are
-- the alert's original look.
function CS:PushoffLook()
    local a = RC.db and RC.db.buffPushoffAlert
    local l = a and a.look
    return type(l) == "table" and l or {}
end
-- what nil means for the alert's animations: shown at once, faded out
-- over half a second (the old PopOut)
CS.PUSHOFF_SHOW_ANIM = { style = "none", duration = 0.3 }
CS.PUSHOFF_HIDE_ANIM = { style = "fade", duration = 0.5, easing = "easeInOutQuad" }

function CS:CreateBuffPushoffAlertFrame()
    if self.alertFrame then return self.alertFrame end

    local frame = self:NewPushoffAlertFrame(UIParent, "WR_BuffPushoffAlert")
    frame:SetFrameStrata("HIGH")
    frame:SetFrameLevel(100)

    RC.Position.Bind(frame, function()
        RC.db.buffPushoffAlert = RC.db.buffPushoffAlert or {}
        return RC.db.buffPushoffAlert
    end, { point = "CENTER", pointKey = "anchorPoint", default = { x = 0, y = 150 } })
    RC.Position.RestoreFrame(frame)

    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    RC.Position.MakeMovable(frame, function()
        return not RC.db.buffPushoffAlert or not RC.db.buffPushoffAlert.locked
    end)

    frame:Hide()
    self.alertFrame = frame
    self.buffPushoffAlertFrame = frame

    RC:DebugPrint("BuffPushoffAlert: Created alert frame", "charstats")
    return frame
end

function CS:UpdateBuffPushoffAlertAppearance()
    if not self.alertFrame then return end

    local settings = RC.db.buffPushoffAlert or {}
    local iconSize = settings.iconSize or 32
    local fontSize = settings.fontSize or 18

    if self.alertFrame.icon then
        self.alertFrame.icon:SetSize(iconSize, iconSize)
    end

    if self.alertFrame.text then
        RC:ApplyCustomFont(self.alertFrame.text, fontSize)
    end

    RC:DebugPrint("BuffPushoffAlert: Updated appearance - icon: " .. iconSize .. ", font: " .. fontSize, "charstats")
end

-- Multiple pushoffs within this window are shown as one stacked alert instead
-- of spamming several popups back to back.
CS.alertBatch = {}
CS.alertBatchTimer = nil
CS.ALERT_BATCH_WINDOW = 1.0

-- by: the names of the buffs that arrived and took the slot (from the
-- counter), shown under the alert and spoken when those options are on.
function CS:QueueBuffPushoffAlert(buffName, buffIcon, by)
    table.insert(self.alertBatch, {name = buffName, icon = buffIcon, by = by, queuedAt = GetTime()})
    RC:DebugPrint("BuffPushoffAlert: Queued alert for " .. (buffName or "Unknown") .. " (batch size: " .. #self.alertBatch .. ")", "charstats")

    if self.alertBatchTimer then
        self.alertBatchTimer:Cancel()
        self.alertBatchTimer = nil
    end

    self.alertBatchTimer = C_Timer.NewTimer(self.ALERT_BATCH_WINDOW, function()
        CS:ShowBatchedAlerts()
    end)
end

function CS:ShowBatchedAlerts()
    self.alertBatchTimer = nil

    if #self.alertBatch == 0 then return end

    local settings = RC.db.buffPushoffAlert
    if not settings or not settings.enabled then
        self.alertBatch = {}
        return
    end

    local alerts = {}
    for _, alertData in ipairs(self.alertBatch) do
        table.insert(alerts, alertData)
    end
    self.alertBatch = {}

    self:ShowMultiBuffPushoffAlert(alerts)
end

-- Restyles and fills an alert frame (live or preview) from the settings:
-- one row per pushed-off buff. Pure drawing - no show, no timers.
function CS:LayoutPushoffAlert(frame, alerts, settings)
    settings = settings or {}
    local look = self:PushoffLook()
    local pad = look.padding or 10

    local bgColor = RC:GetColor("buffPushoffAlert", "background")
    if look.bgTexture == nil then
        frame.bg:SetColorTexture(bgColor.r, bgColor.g, bgColor.b, bgColor.a or 0.8)
    else
        -- nil = flat, "" = the global texture, else an LSM name
        RC:ApplyTextureSpec(frame.bg, (look.bgTexture ~= "" and look.bgTexture) or nil)
        frame.bg:SetVertexColor(bgColor.r, bgColor.g, bgColor.b, bgColor.a or 0.8)
    end
    local showBg = settings.showBackground ~= false
    frame.bg:SetShown(showBg)

    local textColor = RC:GetColor("buffPushoffAlert", "text")
    local borderColor = RC:GetColor("buffPushoffAlert", "border")

    if frame.border then
        for _, side in ipairs({ "top", "bottom", "left", "right" }) do
            frame.border[side]:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, borderColor.a or 1)
            frame.border[side]:SetShown(showBg)
        end
    end

    local iconSize = settings.iconSize or 32
    local fontSize = settings.fontSize or 18
    local textFormat = settings.textFormat or "%s pushed off!"
    local showPusher = settings.showPusher ~= false
    local subSize = math_max(9, math_floor(fontSize * 0.6 + 0.5))
    -- the pusher line keeps its derived size until it is given one
    if type(look.subFont) == "table" and tonumber(look.subFont.size) then subSize = tonumber(look.subFont.size) end
    local numAlerts = #alerts
    -- a row is the icon, or the title plus (when there is one) the "by"
    -- line, whichever is taller; rows sit 6px apart
    local function RowHeight(a)
        local textH = fontSize + 4
        if showPusher and a.by and #a.by > 0 then textH = textH + subSize + 3 end
        return math_max(iconSize, textH)
    end

    if frame.rows then
        for _, row in ipairs(frame.rows) do
            row:Hide()
        end
    end
    frame.rows = frame.rows or {}

    if frame.icon then frame.icon:Hide() end
    if frame.text then frame.text:Hide() end

    local gray = look.subColor or RC:GetColor("text", "gray")
    local ring = RC:GetColor("ui", "borderNormal")
    -- buffPushoffAlert.anchors.title / .sub: a spec moves the text from
    -- where the row puts it (to = "row" / "icon" / "title" / "frame")
    local anc = type(settings.anchors) == "table" and settings.anchors or nil
    local maxTextWidth = 0
    local y = -pad
    for i, alertData in ipairs(alerts) do
        local row = frame.rows[i]
        if not row then
            row = CreateFrame("Frame", nil, frame)
            frame.rows[i] = row

            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)
            row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            row.ring = row:CreateTexture(nil, "ARTWORK", nil, -1)
            row.ring:SetPoint("TOPLEFT", row.icon, "TOPLEFT", -1, 1)
            row.ring:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", 1, -1)

            row.text = RC:CreateFontString(row, "OVERLAY", nil, fontSize)
            row.text:SetJustifyH("LEFT")
            row.text:SetWordWrap(false)
            row.text:SetShadowOffset(1, -1)
            row.text:SetShadowColor(0, 0, 0, 1)

            row.sub = RC:CreateFontString(row, "OVERLAY", nil, subSize)
            row.sub:SetJustifyH("LEFT")
            row.sub:SetWordWrap(false)
            row.sub:SetShadowOffset(1, -1)
            row.sub:SetShadowColor(0, 0, 0, 1)
        end
        local rowH = RowHeight(alertData)
        row:SetHeight(rowH)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame, "TOPLEFT", pad, y)
        row:SetPoint("RIGHT", frame, "RIGHT", -pad, 0)
        y = y - rowH - 6

        local hasIcon = settings.showIcon ~= false and alertData.icon
        if hasIcon then
            row.icon:SetTexture(alertData.icon)
            row.icon:SetSize(iconSize, iconSize)
            row.ring:SetColorTexture(ring.r, ring.g, ring.b, 1)
            row.icon:Show()
            row.ring:Show()
        else
            row.icon:Hide()
            row.ring:Hide()
        end

        local sub = (showPusher and alertData.by and #alertData.by > 0)
            and (RCL["by "] .. table.concat(alertData.by, ", ")) or nil
        if settings.showText ~= false then
            -- own font (size on the old fontSize key), shadow as before
            RC:ApplyFontSpec(row.text, look.font, { size = fontSize, shadow = true })
            row.text:SetTextColor(textColor.r, textColor.g, textColor.b, textColor.a or 1)
            row.text:SetText(string_format(textFormat, alertData.name or "Unknown buff"))
            row.text:ClearAllPoints()
            local tx = hasIcon and (iconSize + 8) or 0
            local function To(k)
                if k == "icon" then return row.icon elseif k == "title" then return row.text
                elseif k == "frame" then return frame elseif k == "row" then return row end
            end
            row._apTitleDef = row._apTitleDef or {}
            if sub then
                -- title on top, the pusher under it, the pair centred on the icon
                local ty = -(rowH - (fontSize + 4 + subSize + 3)) / 2
                row.text:SetPoint("TOPLEFT", row, "TOPLEFT", tx, ty)
                if anc then RC.UI:AnchorOver(row.text, anc.title, row._apTitleDef, "TOPLEFT", row, "TOPLEFT", tx, ty, To) end
                RC:ApplyFontSpec(row.sub, look.subFont, { size = subSize, shadow = true })
                row.sub:SetTextColor(gray.r, gray.g, gray.b, 1)
                row.sub:SetText(sub)
                row.sub:ClearAllPoints()
                row.sub:SetPoint("TOPLEFT", row.text, "BOTTOMLEFT", 1, -3)
                if anc then
                    row._apSubDef = row._apSubDef or {}
                    RC.UI:AnchorOver(row.sub, anc.sub, row._apSubDef, "TOPLEFT", row.text, "BOTTOMLEFT", 1, -3, To)
                end
                row.sub:Show()
                maxTextWidth = math_max(maxTextWidth, row.sub:GetStringWidth() or 0)
            else
                row.text:SetPoint("LEFT", row, "LEFT", tx, 0)
                if anc then RC.UI:AnchorOver(row.text, anc.title, row._apTitleDef, "LEFT", row, "LEFT", tx, 0, To) end
                row.sub:Hide()
            end
            row.text:Show()
            maxTextWidth = math_max(maxTextWidth, row.text:GetStringWidth() or 0)
        else
            row.text:Hide()
            row.sub:Hide()
        end

        row:Show()
    end

    local totalWidth = pad * 2
    if settings.showIcon ~= false then
        totalWidth = totalWidth + iconSize + 8
    end
    if settings.showText ~= false then
        totalWidth = totalWidth + math_max(maxTextWidth, 150)
    end
    frame:SetWidth(math_min(totalWidth, look.width or 420))
    frame:SetHeight(-y + pad - 6)
    -- layer / scale / clamp, fade rules, edge (the customization standard)
    if RC.ApplyFrameCustom then
        RC:ApplyFrameCustom(frame, function() return RC.db and RC.db.buffPushoffAlert end, { sample = (frame ~= self.alertFrame) })
    end
end

function CS:ShowMultiBuffPushoffAlert(alerts)
    local settings = RC.db.buffPushoffAlert
    if not settings or not settings.enabled then return end
    if not alerts or #alerts == 0 then return end

    local frame = self:CreateBuffPushoffAlertFrame()
    if not frame then return end

    frame:SetScript("OnUpdate", nil)
    -- back at rest before it is moved or resized
    if RC.UI and RC.UI.StopAnimations then RC.UI:StopAnimations(frame) end

    RC.Position.RestoreFrame(frame)
    self:LayoutPushoffAlert(frame, alerts, settings)
    local look = self:PushoffLook()

    frame:SetAlpha(1)
    -- entrance and exit are the page's animation settings; their
    -- defaults are the old instant show and half-second fade
    RC.Motion.Show(frame, RC.Motion.Normalize(look.showAnim, CS.PUSHOFF_SHOW_ANIM))

    local duration = settings.duration or 3

    if self.alertFadeTimer then
        self.alertFadeTimer:Cancel()
        self.alertFadeTimer = nil
    end

    self.alertFadeTimer = C_Timer.NewTimer(duration, function()
        self.alertFadeTimer = nil
        if not frame:IsShown() then return end
        RC.Motion.Hide(frame, RC.Motion.Normalize(CS:PushoffLook().hideAnim, CS.PUSHOFF_HIDE_ANIM))
    end)

    local buffNames = {}
    for _, a in ipairs(alerts) do
        table.insert(buffNames, a.name or "Unknown")
    end
    RC:DebugPrint("BuffPushoffAlert: Showing multi-alert for " .. #alerts .. " buffs: " .. table.concat(buffNames, ", "), "charstats")

    if RC.SpeakTTS and RC.db and RC.db.buffPushoffAlert and RC.db.buffPushoffAlert.ttsEnabled then
        -- "... pushed off by Battle Shout": the first pusher only; the
        -- voice line has to stay short enough to land mid-fight
        local byText = ""
        if settings.ttsPusher then
            local by = alerts[1].by
            if #alerts > 1 then
                for _, a in ipairs(alerts) do if a.by and #a.by > 0 then by = a.by break end end
            end
            if by and #by > 0 then
                local pusher = RC.GetTTSName and RC:GetTTSName(by[1]) or by[1]
                byText = RCL[" by "] .. pusher
            end
        end
        if #alerts == 1 then
            local fullName = buffNames[1]
            local shortName = RC.GetTTSName and RC:GetTTSName(fullName) or fullName
            RC:SpeakTTS(shortName .. RCL[" pushed off"] .. byText, true)
        else
            RC:SpeakTTS(#alerts .. RCL[" buffs pushed off"] .. byText, true)
        end
    end
end

function CS:ShowBuffPushoffAlert(buffName, buffIcon)
    self:ShowMultiBuffPushoffAlert({{name = buffName, icon = buffIcon}})
end

-- Dying, being brought back and a loading screen all take buffs off in
-- ways that are not the cap's doing: for a few seconds after each, a
-- push-off is not reported.
function CS:InitializeBuffPushoffTracking()
    if self.buffTrackingInitialized then return end
    -- off where buffs cannot be read in a fight (Core_Flavor)
    if not RC:FeatureOn("buff_pushoff") then return end
    -- the 16-debuff limit is Classic Era's; elsewhere a lost fortune is
    -- reported as gone, never as pushed off
    if RC:Flavor() ~= "era" then self.PLAYER_DEBUFF_CAP = nil end

    self.buffTrackingInitialized = true
    self.playerDeathTime = nil
    self.resurrectionTime = nil
    self.zoneChangeTime = nil
    self.DEATH_GRACE_PERIOD = 3
    self.RESURRECTION_GRACE_PERIOD = 3
    self.ZONE_CHANGE_GRACE_PERIOD = 5

    local function ClearBatch()
        if self.alertBatch then
            for k in pairs(self.alertBatch) do
                self.alertBatch[k] = nil
            end
        end
        if self.alertBatchTimer then
            self.alertBatchTimer:Cancel()
            self.alertBatchTimer = nil
        end
    end

    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_DEAD")
    eventFrame:RegisterEvent("PLAYER_ALIVE")
    eventFrame:RegisterEvent("PLAYER_UNGHOST")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_ENTERING_WORLD" then
            self.zoneChangeTime = GetTime()
            ClearBatch()
            RC:DebugPrint("BuffPushoffAlert: Zone change - grace period started", "charstats")
        elseif event == "PLAYER_DEAD" then
            self.playerDeathTime = GetTime()
            self.resurrectionTime = nil
            ClearBatch()
            RC:DebugPrint("BuffPushoffAlert: Player died - grace period started", "charstats")
        else
            self.resurrectionTime = GetTime()
            self.playerDeathTime = nil
            RC:DebugPrint("BuffPushoffAlert: Player resurrected - grace period started", "charstats")
        end
    end)
    self.buffTrackingFrame = eventFrame

    local BC = RC.BuffCap
    if BC then
        BC:OnPushedOff("charstats", function(lost, _, by) CS:OnBuffsPushedOff(lost, by) end)
        BC:Subscribe("charstats", function(st) CS:OnBuffCapRefreshed(st) end)
    end
    self:UpdateBuffCapWant()
    RC:DebugPrint("BuffPushoffAlert: Tracking initialized", "charstats")

    -- the debuff-side watch shares the death / zone grace times set above
    self:InitializeDmfDebuffWatch()
end

-- The counter only runs while something here needs it: the Buffs cell,
-- the pushoff popup or the chat warning.
function CS:UpdateBuffCapWant()
    local BC = RC.BuffCap
    if not (BC and RC.db) then return end
    local alert = RC.db.buffPushoffAlert
    local cell = RC.db.showStatsBar and self.barStatTexts and self.barStatTexts.buffs ~= nil
    BC:Want("charstats", (BC:Setting("chatWarn") or (alert and alert.enabled) or cell) and true or false)
end

function CS:OnBuffCapRefreshed(st)
    if not (self.barFrame and self.barFrame:IsShown() and self.barStatTexts and self.barStatTexts.buffs) then return end
    if self:PaintBuffCapCell(st) then self:LayoutBarStats() end
end

-- The counter saw buffs pushed off by the cap.
function CS:OnBuffsPushedOff(lost, by)
    if UnitIsDeadOrGhost("player") then return end
    local now = GetTime()
    if self.playerDeathTime and (now - self.playerDeathTime) < (self.DEATH_GRACE_PERIOD or 3) then return end
    if self.resurrectionTime and (now - self.resurrectionTime) < (self.RESURRECTION_GRACE_PERIOD or 3) then return end
    if self.zoneChangeTime and (now - self.zoneChangeTime) < (self.ZONE_CHANGE_GRACE_PERIOD or 5) then return end

    local BC = RC.BuffCap
    local warn = BC and BC:Setting("chatWarn")
    local settings = RC.db and RC.db.buffPushoffAlert
    local popup = settings and settings.enabled
    if not (warn or popup) then return end

    local lookup = self:BuildConsumableBuffLookup()
    local red = RC:GetColor("text", "red")
    for _, r in ipairs(lost) do
        if RC.potionAbsorbSpellIds and r.id and RC.potionAbsorbSpellIds[r.id] then
            RC:DebugPrint("BuffPushoffAlert: " .. tostring(r.name) .. " is an absorb potion - not reported", "charstats")
        else
            local name = (r.id and lookup[r.id] and lookup[r.id].name) or r.name or RCL["a buff"]
            if warn then
                local line
                if by and #by > 0 then
                    line = string_format(RCL["Buff cap reached: %s was pushed off by %s."], name, table.concat(by, ", "))
                else
                    line = string_format(RCL["Buff cap reached: %s was pushed off."], name)
                end
                RC:Print(string_format("|cff%02x%02x%02x%s|r", red.r * 255, red.g * 255, red.b * 255, line))
            end
            if popup then self:QueueBuffPushoffAlert(name, r.icon, by) end
        end
    end
end

------------------------------------------------------------------------
-- THE DARKMOON FAIRE DEBUFF
-- Sayge's fortune can sit on a character as a DEBUFF rather than a buff,
-- which keeps it clear of the 32-buff cap. It then lives under Era's
-- 16-debuff cap instead, and a boss that keeps putting debuffs on you -
-- the same one over and over counts - can push it off without a word.
-- This says so: a chat line, a raid-warning style line on screen and the
-- raid warning sound, plus the pushoff popup if that is switched on.
--
-- It wakes only when a fortune aura is added, changed or removed (the
-- aura coordinator filters by spell id), so it costs nothing in a fight
-- where the debuff is not involved.
------------------------------------------------------------------------
local SAYGE_FORTUNE_IDS = { 23735, 23736, 23737, 23738, 23766, 23767, 23768, 23769 }
local SAYGE_FORTUNE = {}
for _, id in ipairs(SAYGE_FORTUNE_IDS) do SAYGE_FORTUNE[id] = true end

CS.PLAYER_DEBUFF_CAP = 16

-- The fortune among the player's debuffs (nil if it is not there), and
-- how many debuffs the player has.
function CS:FindDmfDebuff()
    local found
    local debuffs = RC.Auras:Debuffs()
    local count = #debuffs
    for _, d in ipairs(debuffs) do
        if SAYGE_FORTUNE[d.spellId] or d.name:find("Sayge's Dark Fortune", 1, true) then
            found = { name = d.name, icon = d.icon, expirationTime = d.expirationTime, spellId = d.spellId, count = count }
            break
        end
    end
    return found, count
end

local function TimeLeftText(seconds)
    seconds = math_floor(seconds or 0)
    if seconds >= 3600 then
        return string_format("%dh %dm", math_floor(seconds / 3600), math_floor(seconds / 60) % 60)
    elseif seconds >= 60 then
        return string_format("%dm", math_floor(seconds / 60))
    end
    return string_format("%ds", seconds)
end

-- prev: what FindDmfDebuff last saw. left: seconds it still had, if known.
-- count: how many debuffs the player has now.
function CS:AnnounceDmfDebuffLost(prev, left, count)
    local cap = self.PLAYER_DEBUFF_CAP
    local name = (prev and prev.name) or "Sayge's Dark Fortune"
    -- pushed off: the debuffs are still at the cap after it went
    local pushed = cap ~= nil and ((count or 0) >= cap - 1 or ((prev and prev.count) or 0) >= cap)

    local msg, short
    if pushed then
        msg = string_format(RCL["Your Darkmoon Faire debuff (%s) was pushed off by the %d-debuff cap."], name, cap)
        short = RCL["Darkmoon Faire debuff pushed off!"]
    else
        msg = string_format(RCL["Your Darkmoon Faire debuff (%s) is gone."], name)
        short = RCL["Darkmoon Faire debuff lost!"]
    end
    if left and left > 0 then
        msg = msg .. " " .. string_format(RCL["It had %s left."], TimeLeftText(left))
    end

    local red = RC:GetColor("text", "red")
    RC:Print(string_format("|cff%02x%02x%02x%s|r", red.r * 255, red.g * 255, red.b * 255, msg))
    -- chat scrolls away in a fight: say it on screen and out loud as well
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, short, red)
    end
    if PlaySound then PlaySound(8959) end
    local settings = RC.db and RC.db.buffPushoffAlert
    if settings and settings.enabled then
        self:QueueBuffPushoffAlert(RCL["Darkmoon Faire debuff"], prev and prev.icon)
    end
    RC:DebugPrint(string_format("DmfDebuff: lost (pushed=%s, debuffs now %d, left %s)",
        tostring(pushed), count or 0, tostring(left)), "charstats")
end

function CS:CheckDmfDebuff()
    local now = GetTime()
    local cur, count = self:FindDmfDebuff()
    local prev = self._dmfDebuff
    self._dmfDebuff = cur
    if cur or not prev then return end

    local settings = RC.db and RC.db.buffPushoffAlert
    if settings and settings.dmfDebuff == false then return end

    -- Gone. Dying, a loading screen and simply running out are not news.
    if UnitIsDeadOrGhost("player") then return end
    if self.playerDeathTime and (now - self.playerDeathTime) < self.DEATH_GRACE_PERIOD then return end
    if self.resurrectionTime and (now - self.resurrectionTime) < self.RESURRECTION_GRACE_PERIOD then return end
    if self.zoneChangeTime and (now - self.zoneChangeTime) < self.ZONE_CHANGE_GRACE_PERIOD then return end
    local left
    if prev.expirationTime and prev.expirationTime > 0 then
        left = prev.expirationTime - now
        if left <= 5 then return end
    end

    self:AnnounceDmfDebuffLost(prev, left, count)
end

-- What the Buff Pushoff page's Test button shows.
function CS:TestDmfDebuffAlert()
    local icon = GetSpellTexture and GetSpellTexture(23768)
    self:AnnounceDmfDebuffLost({ name = "Sayge's Dark Fortune of Damage", icon = icon, count = self.PLAYER_DEBUFF_CAP or 0 },
        72 * 60, self.PLAYER_DEBUFF_CAP or 0)
end

function CS:InitializeDmfDebuffWatch()
    if self._dmfWatchStarted then return end
    self._dmfWatchStarted = true
    self._dmfDebuff = self:FindDmfDebuff()
    RC:RegisterUnitAuraCallback("DmfDebuffWatch", 0.5, function()
        CS:CheckDmfDebuff()
    end, SAYGE_FORTUNE_IDS)
    RC:DebugPrint("DmfDebuff: watching (on the player now: " .. tostring(self._dmfDebuff ~= nil) .. ")", "charstats")
end

function CS:RefreshAlertFrameColors()
    if not self.alertFrame then return end

    local bgColor = RC:GetColor("buffPushoffAlert", "background")
    self.alertFrame.bg:SetColorTexture(bgColor.r, bgColor.g, bgColor.b, bgColor.a or 0.8)

    local textColor = RC:GetColor("buffPushoffAlert", "text")
    self.alertFrame.text:SetTextColor(textColor.r, textColor.g, textColor.b, textColor.a or 1)

    local borderColor = RC:GetColor("buffPushoffAlert", "border")
    if self.alertFrame.border then
        self.alertFrame.border.top:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, borderColor.a or 1)
        self.alertFrame.border.bottom:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, borderColor.a or 1)
        self.alertFrame.border.left:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, borderColor.a or 1)
        self.alertFrame.border.right:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, borderColor.a or 1)
    end
end

local function tryInitialize()
    if CS._loginInitDone then return end
    if not RC.db or not IsLoggedIn() then
        C_Timer.After(0.5, tryInitialize)
        return
    end
    CS._loginInitDone = true
    local ok, err = pcall(function() CS:Initialize() end)
    if not ok then
        CS._initError = tostring(err)
        RC:Print(RCL["Stats bar failed to initialize: "] .. CS._initError)
    end
end

C_Timer.After(0.5, tryInitialize)

RC:DebugPrint("CharacterStats module loaded", "charstats")
