------------------------------------------------------------------------
-- Readycheck - World Buff Timers UI
-- Sidebar page: engine status, per-layer timers, settings, import/reset.
-- Reads the store live every time the page is built; nothing here caches or
-- writes timer data. Settings are per character and apply immediately,
-- except the engine toggle, which needs a reload to register events.
-- Registers itself as a child page of the World Tools category, falling
-- back to a top-level entry if that category is not loaded yet.
------------------------------------------------------------------------
-- World buffs are Classic Era content: TBC and Forever never run this
-- addon (Readycheck Core_Flavor).
if _G.Readycheck and _G.Readycheck.FeatureOn and not _G.Readycheck:FeatureOn("world_tools") then return end
local RC = _G.Readycheck
if not RC or not RC.WorldBuffTimers then return end
local WBT = RC.WorldBuffTimers

local GRAY  = function() return RC:GetColor("text", "gray")   end
local WHITE = function() return RC:GetColor("text", "normal") end

-- one gray line at most; the rest in its tooltip (RC.UI:CreateHelpLine)
local function AddDesc(card, cy, text)
    return (RC.UI:CreateHelpLine(card, 15, cy, text, { gap = 10 }))
end

-- CreateSettingCheckbox hands its callback straight to SetScript("OnClick"),
-- so the callback is invoked as (checkbutton, mouseButton, isDown) - the
-- first argument is the FRAME, never a boolean. Every other settings page
-- in the addon writes `function(cb) x = cb:GetChecked() end` and is fine.
-- This page's handlers were written as `function(v) x = v end`, which
-- assigned the frame table: always truthy, so unticking a box turned the
-- setting ON and printed "enabled". Normalise here so all thirteen
-- handlers below can keep taking a plain boolean.
local function AddCheck(card, cy, label, checked, onClick)
    local box = RC.UI:CreateSettingCheckbox(card, cy, label, checked, onClick and function(cb)
        onClick(cb:GetChecked() and true or false, cb)
    end)
    return cy - 26, box
end

local function AddLine(card, cy, text, color)
    local fs = RC:CreateFontString(card, "OVERLAY", nil, 11)
    fs:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy)
    fs:SetPoint("RIGHT", card, "RIGHT", -15, 0)
    fs:SetJustifyH("LEFT")
    local c = color or WHITE()
    fs:SetTextColor(c.r, c.g, c.b)
    fs:SetText(text)
    -- (a line long enough to wrap takes the room it wraps into: the
    -- format and mirror notes can run to two lines on a narrow window or
    -- a large font, and sat on the line below)
    local h = fs.GetStringHeight and fs:GetStringHeight() or 0
    return cy - math.max(17, math.ceil(h) + 4)
end

local function fmtRemaining(rem)
    if rem == nil then return "unknown" end
    if rem <= 0 then return "READY" end
    local h = math.floor(rem / 3600)
    local m = math.floor((rem % 3600) / 60)
    if h > 0 then return string.format("%dh %02dm", h, m) end
    return string.format("%dm", m)
end

-- The world map pins, drawn by their own code (WBT_MapPins) with fake
-- timers: three songflower pins (counting down, unknown, nearly back) or
-- the capital readout (two layers).
local function MapPinsPreview()
    if not (WBT.NewFlowerPinSample and RC.UI and RC.UI.DeclarePreview) then return end
    RC.UI:DeclarePreview({
        key = "wbt.mappins", title = RCL["World map pins"],
        width = 180, height = 60,
        build = function(canvas, P)
            P.store.flowers = {}
            for i = 1, 3 do P.store.flowers[i] = WBT.NewFlowerPinSample(canvas) end
            P.store.capital = WBT.NewCapitalSample(canvas)
        end,
        update = function(canvas, P)
            local st = P.store
            local capital = P.mode == "capital"
            for i, pin in ipairs(st.flowers) do
                pin:ClearAllPoints()
                pin:SetPoint("TOP", canvas, "TOP", (i - 2) * 46, -8)
                pin.text:SetText(WBT.FlowerTimeText(({ 754, nil, 63 })[i]))
                pin:SetShown(not capital)
            end
            st.capital:ClearAllPoints()
            st.capital:SetPoint("TOPLEFT", canvas, "TOPLEFT", 6, -6)
            WBT.FillCapitalSample(st.capital, {
                { label = "L1", cells = { "1:12:40", "|cff33ff33Ready|r" } },
                { label = "L2", cells = { "|cff777777?|r", "3:05:12" } },
            })
            st.capital:SetShown(capital)
            if capital then P.Resize(st.capital:GetWidth() + 12, st.capital:GetHeight() + 12)
            else P.Resize(150, 40) end
        end,
        modes = { { id = "flowers", label = RCL["Songflowers"] }, { id = "capital", label = RCL["Capital timers"] } },
        modesLabel = RCL["Show"],
    })
end

function RC:ShowSidebarWBTNetwork(frame, preserveScroll)
    self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
    local parent = frame.scrollChild
    local s = WBT:Settings()
    local yPos = -20
    MapPinsPreview()

    local _, newY = self:CreateSettingsPageHeader(parent, yPos,
        "Buff Timer Network",
        "Native world buff timer database, synced with guild timer addons",
        "Interface\\Icons\\INV_Misc_Head_Dragon_01")
    yPos = newY

    ----------------------------------------------------------------
    local card = self:CreateSettingsCard(parent, yPos, "Status")
    local cy = -35

    local mode, modeColor
    if not s.enabled then
        mode = "DISABLED"
        modeColor = RC:GetColor("text", "red")
    elseif WBT:IsMirroring() then
        mode = "MIRRORING - NovaWorldBuffs is running; this engine only copies its data. Disable NWB to go active."
        modeColor = RC:GetColor("text", "orange")
    else
        mode = "ACTIVE - receiving and sending guild timer data natively."
        modeColor = RC:GetColor("text", "green")
    end
    cy = AddLine(card, cy, mode, modeColor)
    cy = cy - 4

    -- networkUsers is filled from guild-channel traffic only, so this counts
    -- guildies running a compatible timer addon, not mesh peers.
    local users = 0
    for _ in pairs(WBT.networkUsers) do users = users + 1 end
    cy = AddLine(card, cy, "Network users seen this session: " .. users)
    cy = AddLine(card, cy, "Newest client version seen: " .. tostring(WBT.newestSeenVersion))
    -- which timer format is spoken, and whether anything newer has been
    -- heard that could not be read (WBT_Comms: Comms.Drift)
    local health
    if WBT:IsMirroring() then
        health = WBT.MirrorStatus and WBT:MirrorStatus()
    elseif WBT.Comms and WBT.Comms.Drift and WBT.Comms.Drift.Status then
        health = WBT.Comms.Drift:Status()
    end
    for _, line in ipairs(health or {}) do
        cy = AddLine(card, cy, line[1], line[2] == "warn" and RC:GetColor("text", "orange") or nil)
    end
    local store = WBT:Store()
    local lastImport = store and store.imported[WBT.realm .. "-" .. WBT.faction]
    if lastImport then
        cy = AddLine(card, cy, "Last legacy import: " .. math.floor((GetServerTime() - lastImport) / 60) .. "m ago")
    end
    if WBT.lastKnownLayer > 0 then
        cy = AddLine(card, cy, "Current layer: " .. WBT.lastKnownLayer .. " (zone " .. WBT.lastKnownLayerID .. ")")
    else
        cy = AddLine(card, cy, "Current layer: unknown (target a city NPC)", GRAY())
    end
    card:SetHeight(-cy + 12)
    yPos = yPos - card:GetHeight() - 10

    ----------------------------------------------------------------
    local tCard = self:CreateSettingsCard(parent, yPos, "Timers")
    cy = -35
    local d = WBT:Data()
    if d then
        local shown = false
        if WBT:IsLayered() and next(d.layers) then
            local keys = {}
            for k in pairs(d.layers) do keys[#keys + 1] = k end
            table.sort(keys)
            -- Layer numbering is the local sort position of the zoneID, so
            -- "Layer 2" here need not be another player's layer 2.
            for i, k in ipairs(keys) do
                local v = d.layers[k]
                local function rem(field, cd)
                    local t = tonumber(v[field])
                    if t and t > 0 then return (t + cd) - GetServerTime() end
                end
                -- No Nef column: the Head of Nefarian turn-in has no
                -- cooldown on Era/Anniversary, so there is nothing to count
                -- down. nefTimer is still received and relayed for the
                -- shared NWB pool, it just is not a timer here.
                cy = AddLine(tCard, cy, string.format("Layer %d:  Rend %s  -  Ony %s", i,
                    fmtRemaining(rem("rendTimer", WBT.rendCooldown)),
                    fmtRemaining(rem("onyTimer", WBT.onyCooldown))))
                shown = true
            end
        end
        if not shown then
            local timers = WBT:GetTimers()
            cy = AddLine(tCard, cy, "Rend: " .. fmtRemaining(timers and timers.warchief))
            cy = AddLine(tCard, cy, "Rally (Onyxia): " .. fmtRemaining(timers and timers.rally))
        end
        local flowers = WBT:GetFlowerTimes()
        local active = 0
        if flowers then
            for _, t in pairs(flowers) do
                if (t + WBT.FLOWER_CD) - GetServerTime() > 0 then active = active + 1 end
            end
        end
        cy = AddLine(tCard, cy, "Songflowers on cooldown: " .. active)
        local dmf = WBT:GetSelfDMFRemaining()
        cy = AddLine(tCard, cy, "DMF fortune lockout: " .. (dmf and fmtRemaining(dmf) or "none"))
        local opp = WBT:GetOppOnyRemaining()
        if opp then
            cy = AddLine(tCard, cy, "Opposite faction Ony: " .. fmtRemaining(opp))
        end
    else
        cy = AddLine(tCard, cy, "Store not ready.", GRAY())
    end
    tCard:SetHeight(-cy + 12)
    yPos = yPos - tCard:GetHeight() - 10

    ----------------------------------------------------------------
    local sCard = self:CreateSettingsCard(parent, yPos, "Settings")
    cy = -35
    local engineCb
    cy, engineCb = AddCheck(sCard, cy, "Enable timer network engine", s.enabled, function(v)
        -- SetEnabled applies immediately - it registers or unregisters the
        -- comms and detection events rather than waiting for a reload - and
        -- reports back what it settled on, which is "mirroring" rather than
        -- "enabled" while NovaWorldBuffs is loaded.
        WBT:SetEnabled(v)
        local state = (not WBT:Settings().enabled and "disabled")
            or (WBT:IsMirroring() and "enabled, mirroring NovaWorldBuffs" or "enabled")
        RC:Print("World Buff Timer Network " .. state .. ". Stored timers are kept either way.")
        -- The Status card at the top of this page is a snapshot taken when
        -- the page was drawn, so it has to be rebuilt or it keeps claiming
        -- ACTIVE after the engine has been switched off. preserveScroll
        -- keeps the view where it is instead of jumping to the top.
        RC:ShowSidebarWBTNetwork(frame, true)
    end)
    local engineMark = RC.UI:MarkCard(sCard)
    cy = AddCheck(sCard, cy, "Send our data to the guild network", s.send, function(v)
        s.send = v
    end)
    cy = AddCheck(sCard, cy, "Start pull bars from relayed guild yells", s.relayBars, function(v)
        s.relayBars = v
    end)
    cy = AddCheck(sCard, cy, "Alerts for relayed yells and drops", s.relayAlerts, function(v)
        s.relayAlerts = v
    end)
    cy = AddCheck(sCard, cy, "Alerts when buff NPCs are killed", s.npcKilledAlerts, function(v)
        s.npcKilledAlerts = v
    end)
    cy = AddCheck(sCard, cy, "Print nearby quest hand-in messages", s.handInMsgs, function(v)
        s.handInMsgs = v
    end)
    cy = AddCheck(sCard, cy, "Warn 10 minutes before a cooldown is ready", s.warn10, function(v)
        s.warn10 = v
    end)
    cy = AddCheck(sCard, cy, "Warn 1 minute before a cooldown is ready", s.warn1, function(v)
        s.warn1 = v
    end)
    cy = AddCheck(sCard, cy, "Announce when a cooldown becomes ready", s.warn0, function(v)
        s.warn0 = v
    end)
    cy = AddCheck(sCard, cy, "World map pins (Felwood flowers + capital CDs)", s.mapPins, function(v)
        s.mapPins = v
        if WBT.RefreshMapPins then WBT.RefreshMapPins() end
    end)
    cy = AddCheck(sCard, cy, "Minimap songflower pins (in Felwood)", s.minimapPins ~= false, function(v)
        s.minimapPins = v
        if WBT.RefreshMinimapPins then WBT.RefreshMinimapPins() end
    end)
    cy = AddCheck(sCard, cy, "Also sync timers over the mesh network", s.meshSync ~= false, function(v)
        s.meshSync = v
        -- Starts or stops the mesh heartbeat to match; a lone broadcast
        -- left the ticker in whatever state login put it in.
        if WBT.ApplyEnabledState then WBT:ApplyEnabledState() end
        if v and WBT.Mesh then WBT.Mesh:Broadcast(true) end
    end)
    RC.UI:BindDependents(engineCb, RC.UI:CardSince(sCard, engineMark))
    sCard:SetHeight(-cy + 12)

    yPos = yPos - sCard:GetHeight() - 10

    ----------------------------------------------------------------
    local aCard = self:CreateSettingsCard(parent, yPos, "Actions")
    cy = -35
    cy = AddDesc(aCard, cy,
        "Import merges timers, layers and DMF lockouts from NovaWorldBuffs saved data. "
        .. "Run it once before disabling NWB (it also runs automatically while NWB is loaded).")
    local importBtn = RC.UI:CreateStyledButton(aCard, "Import from NovaWorldBuffs", 200, 24)
    importBtn:SetPoint("TOPLEFT", aCard, "TOPLEFT", 15, cy)
    importBtn:SetScript("OnClick", function()
        WBT:ImportLegacyData(true)
        RC:ShowSidebarWBTNetwork(frame, true)
    end)
    cy = cy - 32
    local resetBtn = RC.UI:CreateStyledButton(aCard, "Reset timer data", 200, 24)
    resetBtn:SetPoint("TOPLEFT", aCard, "TOPLEFT", 15, cy)
    resetBtn:SetScript("OnClick", function()
        RC.UI:CreateConfirmDialog("Reset timer data",
            "Wipe all stored world buff timers, layers and network data?",
            -- Caches invalidated on the spot: without this the running
            -- session kept reading - and BROADCASTING - the detached table
            -- until the next /reload, re-sharing the very timers the user
            -- just wiped.
            function()
                if ReadycheckDB then ReadycheckDB.worldBuffTimers = nil end
                if WBT.InvalidateCaches then WBT:InvalidateCaches() end
                RC:Print("World Buff Timers: data wiped - /reload to reinitialize.")
            end, nil, "Wipe", true)
    end)
    cy = cy - 36
    aCard:SetHeight(-cy + 12)
    yPos = yPos - aCard:GetHeight() - 10

    self:UpdateSidebarScrollbar(frame, -yPos + 40)
end

-- Register as a child page of the World Tools category.
local function registerPage()
    for _, item in ipairs(RC.MenuStructure or {}) do
        if item.id == "world_tools" and item.children then
            for _, child in ipairs(item.children) do
                if child.id == "wt_buffnetwork" then return end
            end
            -- right under Buff Drops (the two timer pages together)
            local at = #item.children + 1
            for i, child in ipairs(item.children) do
                if child.id == "wt_pulltimers" then at = i + 1 break end
            end
            table.insert(item.children, at, {
                id = "wt_buffnetwork",
                name = "Buff Timer Network",
                icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01",
                panel = "ShowSidebarWBTNetwork",
                aliases = { "buff timer network", "world buff timers", "nova", "timer sync", "layer" },
            })
            return
        end
    end
    -- Fallback: own top-level entry if World Tools isn't registered.
    table.insert(RC.MenuStructure, {
        id = "wt_buffnetwork",
        name = "Buff Timer Network",
        icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01",
        panel = "ShowSidebarWBTNetwork",
        aliases = { "buff timer network", "world buff timers", "timer sync" },
    })
end

if RC.MenuStructure then
    registerPage()
else
    C_Timer.After(2, function()
        if RC.MenuStructure then registerPage() end
    end)
end

SLASH_READYCHECKWBTNET1 = "/wbtnet"
SlashCmdList["READYCHECKWBTNET"] = function(msg)
    -- "/wbtnet off" is the quickest way out of the network without hunting
    -- for the settings page, and applies straight away like the checkbox.
    local arg = string.lower(string.match(tostring(msg or ""), "^%s*(%S*)") or "")
    if arg == "on" or arg == "off" or arg == "toggle" then
        local want = (arg == "toggle") and (not WBT:Settings().enabled) or (arg == "on")
        WBT:SetEnabled(want)
        RC:Print("Buff Timer Network " .. (want and "enabled" or "disabled")
            .. " - applied now, no reload needed. Stored timers are kept.")
        return
    end

    -- "/wbtnet diag" answers "why is nothing syncing" in one shot. Every
    -- gate between a local drop and a peer seeing it is separate and any
    -- one of them silently stops the lot, so they are printed together
    -- rather than guessed at one at a time.
    if arg == "diag" then
        local s  = WBT:Settings()
        local MS = RC.MeshSync
        local function yn(v, why)
            return (v and "|cff33ff33yes|r" or ("|cffff5555NO|r" .. (why and (" - " .. why) or "")))
        end
        RC:Print("|cffffd200Buff timer / mesh diagnostic|r")
        RC:Print("  engine enabled (worldBuffTimers.enabled): "
            .. yn(s.enabled, "tick it on the Buff Timer Network page, or /wbtnet on"))
        RC:Print("  timers over mesh (worldBuffTimers.meshSync): "
            .. yn(s.meshSync ~= false, "tick 'Also sync timers over the mesh network'"))
        RC:Print("  mesh itself enabled: "
            .. yn(MS and MS.IsEnabled and MS:IsEnabled(), "enable it on the Mesh Network page"))
        RC:Print("  mirror mode (NovaWorldBuffs loaded): "
            .. (WBT:IsMirroring() and "|cffffcc00yes - detection and comms are off|r" or "no"))
        RC:Print("  WBTIME broadcast running: "
            .. yn(WBT.Mesh and WBT.Mesh._ticker ~= nil))

        -- What this client would actually put on the wire right now.
        local payload = WBT.Mesh and WBT.Mesh.Encode and WBT.Mesh:Encode()
        RC:Print("  next WBTIME payload: "
            .. (payload and ("|cff33ff33" .. payload .. "|r")
                or "|cffff5555nothing to send|r - no live rend/ony/flower stamps"))

        local flowers, nf = WBT:GetFlowerTimes(), 0
        if flowers then for _ in pairs(flowers) do nf = nf + 1 end end
        RC:Print("  local songflower stamps: " .. nf .. " of 10")

        -- Gold rides the WorldBuffSync WBUFF payload, not WBTIME, so it can
        -- fail independently of everything above.
        local WBS = RC.WorldBuffs
        if WBS and type(WBS.peers) == "table" then
            local peers, withGold, withBuffs = 0, 0, 0
            for _, p in pairs(WBS.peers) do
                if type(p) == "table" then
                    peers = peers + 1
                    if (p.gold or 0) > 0 then withGold = withGold + 1 end
                    if p.buffs and next(p.buffs) then withBuffs = withBuffs + 1 end
                end
            end
            RC:Print("  WBUFF peers: " .. peers .. " (" .. withBuffs
                .. " carrying buffs, " .. withGold .. " carrying gold)")
            if peers > 0 and withGold == 0 then
                RC:Print("    |cffff5555gold absent from every peer|r - the sender is"
                    .. " omitting it, not the receiver dropping it")
            end
        else
            RC:Print("  WBUFF peers: |cffff5555none|r - Readycheck_WorldTools may be off")
        end
        return
    end

    -- "/wbtnet peer <name>" dumps one stored board record raw. The board
    -- shows a record aged forward from when it arrived, so a row claiming
    -- a buff the character no longer has is either a stale snapshot that
    -- never got replaced, or one being held frozen. Those look identical
    -- on the board and completely different here.
    if arg == "peer" then
        local want = string.lower(string.match(tostring(msg or ""), "^%s*%S+%s+(%S+)") or "")
        local WBS = RC.WorldBuffs
        if want == "" or not WBS or type(WBS.peers) ~= "table" then
            RC:Print("Usage: /wbtnet peer <character name>")
            return
        end
        local now = time()
        local found = false
        for key, p in pairs(WBS.peers) do
            if type(p) == "table" and string.find(string.lower(tostring(key)), want, 1, true) then
                found = true
                local age = now - (p.t or 0)
                RC:Print("|cffffd200" .. tostring(key) .. "|r")
                RC:Print("  snapshot age: " .. age .. "s"
                    .. "   booned: " .. tostring(p.booned and true or false)
                    .. "   own: " .. tostring(p.own and true or false))
                RC:Print("  gold: " .. tostring(p.gold) .. "   race: " .. tostring(p.race)
                    .. "   relayOnline: " .. tostring(p.relayOnline))
                -- Frozen entries are chronoboon-stored: the board passes
                -- them through without ageing, so a wrongly-frozen buff sits
                -- there for ever. That is the difference worth seeing.
                local any = false
                if type(p.buffs) == "table" then
                    for k, secs in pairs(p.buffs) do
                        any = true
                        local fz = p.frozen and p.frozen[k]
                        local rem = fz and secs or (secs - age)
                        RC:Print(string.format("    %-14s stored %5ds  ->  %s%s",
                            tostring(k), secs,
                            fz and "|cff33ff33frozen, never ages|r"
                                or (rem > 0 and ("|cffffd200" .. math.floor(rem) .. "s left|r")
                                             or "|cffff5555expired, should not show|r"),
                            fz and "" or ""))
                    end
                end
                if not any then RC:Print("    (no buffs stored)") end
            end
        end
        if not found then RC:Print("No stored record matching '" .. want .. "'.") end
        return
    end
    local s = WBT:Settings()
    local users = 0
    for _ in pairs(WBT.networkUsers) do users = users + 1 end
    RC:Print("Buff Timer Network: " .. (not s.enabled and "disabled"
        or (WBT:IsMirroring() and "mirroring NovaWorldBuffs" or "active"))
        .. ", " .. users .. " network user(s) seen, layers: " .. WBT:GetLayerCount())
    local timers = WBT:GetTimers()
    if timers then
        RC:Print("  Rend " .. fmtRemaining(timers.warchief)
            .. ", Rally " .. fmtRemaining(timers.rally)
            .. ", Songflower " .. fmtRemaining(timers.songflower))
    else
        RC:Print("  No timer data yet.")
    end
end
