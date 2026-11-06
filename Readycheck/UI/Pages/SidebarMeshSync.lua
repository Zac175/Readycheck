------------------------------------------------------------------------
-- Readycheck - Mesh Sync
-- Sidebar page for the peer-to-peer settings-sync network: account
-- identity/channel/password, per-setting send/receive rules (one flat
-- list, every setting its own row), accept-from policy, and manual
-- push/pull actions.
-- Edits MS:GetConfig() (account-wide: label, channel, password, members,
-- cross-faction peers) and, through the MS:*KeySendState/*KeyRecvState
-- helpers, MS:GetCharConfig() (per-character: category flags, per-key
-- exclusion lists for each direction, autoBroadcast, accept-from
-- mode/account list).
------------------------------------------------------------------------
local pairs, ipairs, type, tostring, tonumber, select =
      pairs, ipairs, type, tostring, tonumber, select
local math_floor, math_abs = math.floor, math.abs
local string_format = string.format
local table_sort = table.sort
local CreateFrame, C_Timer = CreateFrame, C_Timer

local function InitializeSidebarMeshSync()
    local RC = _G.Readycheck
    if not RC     then C_Timer.After(0.1, InitializeSidebarMeshSync); return end
    if not RC.UI  then C_Timer.After(0.2, InitializeSidebarMeshSync); return end

    local MIN_PASS_LEN  = 6
    local MAX_LABEL_LEN = 15

    -- Colour a font string from the theme; returns it for chaining.
    local function Tint(fs, cat, key)
        local c = RC:GetColor(cat, key)
        if c then fs:SetTextColor(c.r, c.g, c.b) end
        return fs
    end

    local function NormalFS(parent, text, ax, ay)
        local fs = RC:CreateFontString(parent, "OVERLAY", nil, 11)
        fs:SetPoint("TOPLEFT", parent, "TOPLEFT", ax, ay)
        fs:SetPoint("RIGHT",   parent, "RIGHT",  -14, 0)
        fs:SetJustifyH("LEFT")
        if text then fs:SetText(text) end
        Tint(fs, "text", "normal")
        return fs
    end

    local function DimFS(parent, text, ax, ay)
        local fs = RC:CreateFontString(parent, "OVERLAY", nil, 10)
        fs:SetPoint("TOPLEFT", parent, "TOPLEFT", ax, ay)
        fs:SetPoint("RIGHT",   parent, "RIGHT",  -14, 0)
        fs:SetJustifyH("LEFT")
        if text then fs:SetText(text) end
        Tint(fs, "text", "gray")
        return fs
    end

    -- how far a grey note moves the row down: its real height (it wraps
    -- on a narrow window) plus the gap, at least the one-line pitch
    local function DimAdv(fs)
        return math.max(18, math.ceil(fs:GetStringHeight() or 12) + 8)
    end

    local function GoldFS(parent, text, ax, ay)
        local fs = RC:CreateFontString(parent, "OVERLAY", nil, 11)
        fs:SetPoint("TOPLEFT", parent, "TOPLEFT", ax, ay)
        fs:SetPoint("RIGHT",   parent, "RIGHT",  -14, 0)
        fs:SetJustifyH("LEFT")
        if text then fs:SetText(text) end
        Tint(fs, "ui", "accentGold")
        return fs
    end

    -- A single line assembled from runs, each in its own theme colour
    -- ("Sending" + "3" in green + " of 12 categories"), so a mixed line
    -- needs no inline colour codes and repaints with the theme. Runs are
    -- anchored end to end; put the separating space at the START of the
    -- following run. parts: { {text, cat, key}, ... } (default
    -- text.normal). capRight, if given, pins the last run's right edge
    -- to the parent's right at that offset so a long tail clips instead
    -- of running out of the card. Returns the first and last run.
    local function RunFS(parent, ax, ay, size, parts, capRight)
        local first, prev
        local n = #parts
        for i, part in ipairs(parts) do
            local fs = RC:CreateFontString(parent, "OVERLAY", nil, size or 11)
            -- every part hangs by its top: the capped last part's right
            -- edge is pinned at the same height (a RIGHT-to-RIGHT anchor
            -- would also pull it to the middle of the parent)
            if prev then
                fs:SetPoint("TOPLEFT", prev, "TOPRIGHT", 0, 0)
            else
                fs:SetPoint("TOPLEFT", parent, "TOPLEFT", ax, ay)
                first = fs
            end
            if capRight and i == n then
                fs:SetPoint("TOPRIGHT", parent, "TOPRIGHT", capRight, ay)
            end
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(false)
            fs:SetText(part[1])
            Tint(fs, part[2] or "text", part[3] or "normal")
            prev = fs
        end
        return first, prev
    end

    -- Gold field heading with an optional caution note after it
    -- ("Channel Name" + "(same on ALL accounts)" in text.red).
    local function FieldHeading(parent, title, note, ax, ay)
        local fs = GoldFS(parent, title, ax, ay)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", parent, "TOPLEFT", ax, ay)
        if note then
            local nfs = RC:CreateFontString(parent, "OVERLAY", nil, 10)
            nfs:SetPoint("LEFT", fs, "RIGHT", 6, 0)
            nfs:SetText(note)
            Tint(nfs, "text", "red")
        end
        return fs
    end

    local function Dot(parent, r, g, b, ax, ay)
        local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        f:SetSize(8, 8)
        f:SetPoint("TOPLEFT", parent, "TOPLEFT", ax, ay)
        f:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        f:SetBackdropColor(r, g, b, 1)
        local bn = RC:GetColor("ui", "borderNormal") or {r=0,g=0,b=0,a=1}
        f:SetBackdropBorderColor(bn.r, bn.g, bn.b, bn.a or 1)
        return f
    end

    local function AlertBox(parent, lines, ax, ay)
        local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        box:SetPoint("TOPLEFT", parent, "TOPLEFT", ax, ay)
        box:SetPoint("RIGHT",   parent, "RIGHT",  -ax, 0)
        local accentC = RC:GetColor("ui", "accentGold") or {r=0.85,g=0.65,b=0.25}
        local bgC     = RC:GetColor("ui", "elementBackground") or {r=0.07,g=0.07,b=0.07}
        box:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",edgeFile="Interface\\Buttons\\WHITE8X8",edgeSize=1})
        box:SetBackdropColor(bgC.r, bgC.g, bgC.b, 0.9)
        box:SetBackdropBorderColor(accentC.r, accentC.g, accentC.b, 0.8)
        local icon = box:CreateTexture(nil, "ARTWORK")
        icon:SetSize(14, 14)
        icon:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -8)
        icon:SetTexture("Interface\\DialogFrame\\UI-Dialog-Icon-AlertOther")
        local totalH = 8
        -- Each line is a string (text.normal) or {text, cat, key}.
        for _, line in ipairs(lines) do
            local lfs = RC:CreateFontString(box, "OVERLAY", nil, 10)
            lfs:SetPoint("TOPLEFT", box, "TOPLEFT", 28, -totalH)
            lfs:SetPoint("RIGHT",   box, "RIGHT",   -8, 0)
            lfs:SetJustifyH("LEFT")
            if type(line) == "table" then
                lfs:SetText(line[1])
                Tint(lfs, line[2], line[3])
            else
                lfs:SetText(line)
                Tint(lfs, "text", "normal")
            end
            totalH = totalH + 14
        end
        totalH = totalH + 10
        box:SetHeight(totalH)
        return box, -totalH
    end

    ------------------------------------------------------------------
    -- SYNC TRANSFER BAR LOOK (meshProgressBar.look). The bar itself is
    -- drawn by the sync code and never touched here beyond its looks:
    -- StyleMeshBar recolours, re-textures and re-fonts a bar built by the
    -- sync code (it only colours its pieces once, when it makes them) or
    -- the preview's sample. Nothing about when or what it shows changes.
    -- Every nil field is the bar's original look.
    ------------------------------------------------------------------
    local K = RC._disp
    local function MeshLook()
        local m = RC.db and RC.db.meshProgressBar
        local l = m and m.look
        return type(l) == "table" and l or {}
    end
    local function C(field, cat, key, alpha)
        local c = MeshLook()[field] or RC:GetColor(cat, key)
        return c.r, c.g, c.b, alpha or c.a or 1
    end
    -- The sync code keeps its gold rule and row tracks as locals: find them
    -- by layer (the only ARTWORK texture of the bar, the only BACKGROUND
    -- texture of each row).
    local function RegionIn(frame, layer, own)
        if own then return own end
        for _, r in ipairs({ frame:GetRegions() }) do
            if r.GetDrawLayer and r:GetObjectType() == "Texture" and r:GetDrawLayer() == layer then return r end
        end
    end
    local function StyleMeshBar(f)
        if not f then return end
        local look = MeshLook()
        local w = look.width or 240
        f:SetWidth(w)
        if f.bg then f.bg:SetVertexColor(C("bgColor", "ui", "windowBackground")) end
        if f.border and RC.UI.UpdateBorderColor then
            RC.UI:UpdateBorderColor(f.border, look.borderColor or RC:GetColor("ui", "borderNormal"))
        end
        f._rcRule = RegionIn(f, "ARTWORK", f._rcRule)
        if f._rcRule then
            local r, g, b = C("ruleColor", "ui", "accentGold")
            f._rcRule:SetVertexColor(r, g, b, look.ruleColor and (look.ruleColor.a or 1) or 0.6)
        end
        for _, row in ipairs({ f.sendRow, f.recvRow }) do
            if row then
                row:SetWidth(w - 12)
                RC:ApplyBarTexture(row, look.texture)
                row:SetStatusBarColor(C("fillColor", "ui", "accentGreen"))
                row._rcTrack = RegionIn(row, "BACKGROUND", row._rcTrack)
                if row._rcTrack then row._rcTrack:SetVertexColor(C("trackColor", "ui", "cardBackground")) end
                for _, fs in ipairs({ row.label, row.value }) do
                    RC:ApplyFontSpec(fs, look.font, { size = 9 })
                    fs:SetTextColor(C("textColor", "ui", "headerText"))
                end
            end
        end
        -- layer / fade / edge (Transfer Bar tab); the preview's sample
        -- takes the look only. Nothing set = the bar as the sync made it.
        if RC.ApplyFrameCustom then
            RC:ApplyFrameCustom(f, function() return RC.db and RC.db.meshProgressBar end,
                { sample = (f ~= _G.WRMeshProgressBar), parts = { bg = f.bg, border = f.border } })
        end
    end
    RC.StyleMeshProgressBar = StyleMeshBar

    -- The live bar, styled now (made first when it does not exist yet, so
    -- a transfer later uses the styled one).
    local function ApplyMeshLook()
        if RC.EnsureMeshProgressBar then StyleMeshBar(RC.EnsureMeshProgressBar()) end
    end
    -- At login, only when a look was ever set: a default profile gets the
    -- bar exactly as the sync code makes it, when it makes it.
    do
        local ev = CreateFrame("Frame")
        ev:RegisterEvent("PLAYER_LOGIN")
        ev:SetScript("OnEvent", function(self2)
            self2:UnregisterAllEvents()
            C_Timer.After(2, function()
                if next(MeshLook()) ~= nil then ApplyMeshLook() end
            end)
        end)
    end

    -- PREVIEW: the bar's pieces as the sync code lays them out (a sample
    -- on the canvas, styled by the same StyleMeshBar), with made-up
    -- transfers.
    local MB_W, MB_H = 248, 52   -- update sizes the canvas to the bar
    local function MeshSampleRow(f)
        local bar = CreateFrame("StatusBar", nil, f)
        bar:SetSize(228, 15)
        bar:SetMinMaxValues(0, 1)
        local bg = bar:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(RC.UI.FLAT)
        local label = bar:CreateFontString(nil, "OVERLAY")
        label:SetPoint("LEFT", bar, "LEFT", 4, 0)
        label:SetPoint("RIGHT", bar, "RIGHT", -52, 0)
        label:SetJustifyH("LEFT")
        label:SetWordWrap(false)
        local value = bar:CreateFontString(nil, "OVERLAY")
        value:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
        value:SetJustifyH("RIGHT")
        bar.label, bar.value = label, value
        return bar
    end
    local function MeshPreviewBuild(canvas, P)
        local f = CreateFrame("Frame", nil, canvas)
        f:SetSize(240, 44)
        f.bg = f:CreateTexture(nil, "BACKGROUND")
        f.bg:SetAllPoints()
        f.bg:SetTexture(RC.UI.FLAT)
        f.border = RC.UI:CreateSimpleBorder(f)
        local rule = f:CreateTexture(nil, "ARTWORK")
        rule:SetTexture(RC.UI.FLAT)
        rule:SetHeight(1)
        rule:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
        rule:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
        f._rcRule = rule
        f.sendRow = MeshSampleRow(f)
        f.recvRow = MeshSampleRow(f)
        P.store.f = f
    end
    local function MeshPreviewUpdate(canvas, P)
        local f = P.store.f
        if not f then return end
        StyleMeshBar(f)
        local mode = P.mode or "both"
        local rows = {}
        f.sendRow:SetValue(0.62)
        f.sendRow.label:SetText(RCL["Sending sync data"])
        f.sendRow.value:SetText("31/50")
        f.recvRow:SetValue(0.25)
        f.recvRow.label:SetText("Sync data < Zacalt")
        f.recvRow.value:SetText("12/48")
        f.sendRow:SetShown(mode ~= "recv")
        f.recvRow:SetShown(mode ~= "send")
        if mode ~= "recv" then rows[#rows + 1] = f.sendRow end
        if mode ~= "send" then rows[#rows + 1] = f.recvRow end
        for i, row in ipairs(rows) do
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -6 - (i - 1) * 19)
        end
        f:SetHeight(12 + #rows * 19 - 4)
        -- the bar at its real size; the canvas is its box, the strip scales it
        f:SetScale(1)
        f:ClearAllPoints()
        f:SetPoint("CENTER", canvas, "CENTER", 0, 0)
        if P.Resize then P.Resize((f:GetWidth() or 240) + 8, (f:GetHeight() or 44) + 8) end
    end

    local function BuildMeshBarTab(self, parent, yPos)
        local function L()
            -- the sync code fills meshProgressBar (its position) the first
            -- time it makes the bar; let it, before adding the look
            if not (RC.db and RC.db.meshProgressBar) and RC.EnsureMeshProgressBar then RC.EnsureMeshProgressBar() end
            RC.db.meshProgressBar = RC.db.meshProgressBar or {}
            return K.Look(RC.db.meshProgressBar, "look")
        end
        local function Apply() RC:SaveConfigurationToProfile() ApplyMeshLook() end
        yPos = K.Card(parent, yPos, RCL["Sync transfer bar"], function(card, y)
            y = K.Desc(card, y, RCL["The small bar that shows while settings are sent or received. Only its looks are set here; when it shows is up to the sync."])
            y = K.Slider(card, y, RCL["Width"], 180, 420, MeshLook().width or 240, 2,
                function(v) return v .. RCL[" px"] end, function(v) L().width = v Apply() end)
            local tp = self.UI:CreateTexturePicker(card, { label = RCL["Bar texture"], width = 260,
                get = function() return MeshLook().texture end,
                set = function(name) L().texture = name Apply() end,
                color = function() local r, g, b = C("fillColor", "ui", "accentGreen") return r, g, b end })
            tp:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
            y = y - tp:GetHeight() - 12
            return y
        end)
        yPos = K.Card(parent, yPos, RCL["Colours"], function(card, y)
            y = K.LookColor(card, y, RCL["Fill"], L, "fillColor", function() return RC:GetColor("ui", "accentGreen") end, Apply)
            y = K.LookColor(card, y, RCL["Track"], L, "trackColor", function() return RC:GetColor("ui", "cardBackground") end, Apply)
            y = K.LookColor(card, y, RCL["Background"], L, "bgColor", function() return RC:GetColor("ui", "windowBackground") end, Apply, true)
            y = K.LookColor(card, y, RCL["Border"], L, "borderColor", function() return RC:GetColor("ui", "borderNormal") end, Apply, true)
            y = K.LookColor(card, y, RCL["Top line"], L, "ruleColor", function()
                local c = RC:GetColor("ui", "accentGold") return { r = c.r, g = c.g, b = c.b, a = 0.6 } end, Apply, true)
            y = K.LookColor(card, y, RCL["Text colour"], L, "textColor", function() return RC:GetColor("ui", "headerText") end, Apply)
            return y - 4
        end)
        yPos = K.Card(parent, yPos, RCL["Text"], function(card, y)
            return K.Font(card, y, RCL["Bar text"], function() return MeshLook().font end,
                function(spec) L().font = spec Apply() end, { size = 9 }, "Sending sync data   31/50", 6, 16)
        end)
        -- fade, shadow / glow (its own fill and edge are the colours above), layer
        local function Root() return RC.db and RC.db.meshProgressBar end
        local function Ensure()
            if not (RC.db and RC.db.meshProgressBar) and RC.EnsureMeshProgressBar then RC.EnsureMeshProgressBar() end
            RC.db.meshProgressBar = RC.db.meshProgressBar or {}
            return RC.db.meshProgressBar
        end
        yPos = self.UI:FrameVisibilityCard(parent, yPos, Root, Apply, { title = RCL["Bar fade and opacity"], ensure = Ensure,
            note = RCL["On top of when the sync shows it: a rule that is not met fades it out."] })
        yPos = self.UI:FrameChromeCard(parent, yPos, Root, Apply, { title = RCL["Bar shadow and glow"], ensure = Ensure,
            fields = { shadowSize = true, shadowColor = true, glowSize = true, glowColor = true } })
        yPos = self.UI:FrameLayerCard(parent, yPos, Root, Apply, { title = RCL["Bar layer and scale"], ensure = Ensure })
        return yPos
    end

    function RC:ShowSidebarMeshSync(frame)
        self:ClearSidebarContent(self.sidebarConfigFrame, true)
        local parent = frame.scrollChild
        local yPos   = -20

        local _, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Mesh Network"],
            RCL["Sync all Readycheck settings across accounts via direct in-game whispers"],
            "Interface\\Icons\\spell_nature_web")
        yPos = newY - 4

        if not RC.MeshSync then
            DimFS(parent, "Mesh Network module not loaded.", 18, yPos)
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame); return
        end
        local MS   = RC.MeshSync
        -- mcfg: one shared record per WoW account (identity, channel,
        -- password, known members, cross-faction peers). charCfg: per-
        -- character record (which categories THIS toon sends/receives,
        -- accept-from mode/list).
        local mcfg    = MS:GetConfig()
        local charCfg = MS:GetCharConfig()
        if not mcfg then
            DimFS(parent, "Initialising - log in with a character first.", 18, yPos)
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame); return
        end

        local activeTab = RC._meshSyncTab or "setup"
        -- Called by MeshSync itself after network events (join/leave,
        -- roster change) so this page reflects state it didn't cause.
        -- Deferred a frame to let that mesh state finish settling first.
        RC.meshSyncUIRefresh = function()
            C_Timer.After(0, function()
                if RC.sidebarConfigFrame and RC.BuildSidebar then
                    RC:BuildSidebar(RC.sidebarConfigFrame, false)
                end
                if RC.SidebarState and RC.SidebarState.currentPanel == "mesh_sync" then
                    RC:ShowSidebarMeshSync(frame)
                end
            end)
        end

        if activeTab == "bar" then
            self.UI:DeclarePreview({ key = "mesh.transferbar", title = RCL["Sync transfer bar"],
                width = MB_W, height = MB_H, build = MeshPreviewBuild, update = MeshPreviewUpdate,
                modes = { { id = "both", label = RCL["Both"] }, { id = "send", label = RCL["Sending"] },
                          { id = "recv", label = RCL["Receiving"] } } })
        end
        yPos = self:BuildSettingsTabBar(parent, yPos, {
            {"setup",   "Setup"},
            {"sync",    "Sync Rules"},
            {"network", "Network"},
            {"actions", "Actions"},
            {"bar",     RCL["Transfer Bar"]},
        }, activeTab, function(key)
            RC._meshSyncTab = key; RC:ShowSidebarMeshSync(frame)
        end)

        local cats = MS.SYNC_CATEGORIES
        local function Card(title,y) return self:CreateSettingsCard(parent,y,title) end

        if activeTab == "setup" then

            local charEnabledTbl = ReadycheckDB and ReadycheckDB.meshSyncEnabledPerChar
            -- Mesh tables key by the NORMALIZED toon key (see GetToonKey in
            -- Mesh_Proto); hand-built raw keys diverge on realms with spaces.
            local toonK = (RC._mss and RC._mss.GetToonKey and RC._mss.GetToonKey())
                or (UnitName("player") .. "-" .. GetRealmName())
            local charEnabled = charEnabledTbl and charEnabledTbl[toonK] == true
            local enabled = MS:IsEnabled()

            local statusRow = CreateFrame("Frame", nil, parent)
            statusRow:SetHeight(30)
            statusRow:SetPoint("TOPLEFT",  parent, "TOPLEFT",  18, yPos)
            statusRow:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -18, yPos)

            local dot = CreateFrame("Frame", nil, statusRow, "BackdropTemplate")
            dot:SetSize(9, 9)
            dot:SetPoint("LEFT", statusRow, "LEFT", 0, 0)
            dot:SetBackdrop({
                bgFile   = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Buttons\\WHITE8X8",
                edgeSize = 1,
            })
            do local _dc = enabled and RC:GetColor("ui", "configured") or RC:GetColor("raids", "disabled")
                dot:SetBackdropColor(_dc.r, _dc.g, _dc.b, 1) end
            do local _bn = RC:GetColor("ui", "borderNormal")
                dot:SetBackdropBorderColor(_bn.r, _bn.g, _bn.b, _bn.a or 1) end

            local statusLabel = RC:CreateFontString(statusRow, "OVERLAY", nil, 11)
            statusLabel:SetPoint("LEFT", dot, "RIGHT", 7, 0)
            statusLabel:SetText(RCL["Mesh Network:"])
            do local _nc = RC:GetColor("text", "normal"); statusLabel:SetTextColor(_nc.r, _nc.g, _nc.b) end

            -- State word as its own string in text.success / text.disabled
            -- so it follows the theme instead of an inline colour code.
            local stateLabel = RC:CreateFontString(statusRow, "OVERLAY", nil, 11)
            stateLabel:SetPoint("LEFT", statusLabel, "RIGHT", 6, 0)
            stateLabel:SetText(enabled and RCL["Active"] or RCL["Inactive"])
            Tint(stateLabel, "text", enabled and "success" or "disabled")

            local toggleBtn = self.UI:CreateStyledButton(statusRow, charEnabled and RCL["Disable Sync"] or RCL["Enable Sync"], 110, 26)
            toggleBtn:SetPoint("RIGHT", statusRow, "RIGHT", 0, 0)
            -- Enable() requires both fields already saved; this guards
            -- against silently starting a mesh with an empty label or a
            -- password too short to pass the peer handshake.
            toggleBtn:SetScript("OnClick", function()
                if charEnabledTbl and charEnabledTbl[toonK] then
                    MS:Disable()
                else
                    if mcfg.accountLabel == "" then
                        RC:Print(RCL["Mesh: Set your Account Label first."]); return
                    end
                    if #(mcfg.meshPassword or "") < MIN_PASS_LEN then
                        RC:Print(string_format("Mesh: Mesh Password must be %d+ characters.", MIN_PASS_LEN)); return
                    end
                    MS:Enable()
                end
                if RC.sidebarConfigFrame and RC.BuildSidebar then
                    RC:BuildSidebar(RC.sidebarConfigFrame, false)
                end
                RC:ShowSidebarMeshSync(frame)
            end)
            yPos = yPos - 42

            local warnBox, warnH = AlertBox(parent, {
                { "All accounts must use the same Discovery Channel name, Channel Name, and Mesh Password.", "ui", "accentGold" },
                "When any account joins the channel, Readycheck auto-whispers them and saves them to your roster.",
                "No manual member setup needed - the channel handles discovery automatically.",
            }, 18, yPos)
            yPos = yPos + warnH - 10

            local secCard = Card("Privacy & security", yPos)
            local cy = -32
            local function SecLine(txt, yoff)
                local fs = RC:CreateFontString(secCard, "OVERLAY", nil, 10)
                fs:SetPoint("TOPLEFT", secCard, "TOPLEFT", 30, yoff)
                fs:SetPoint("RIGHT", secCard, "RIGHT", -14, 0)
                fs:SetJustifyH("LEFT")
                fs:SetText(txt)
                Tint(fs, "text", "normal")
                local dot = RC:CreateFontString(secCard, "OVERLAY", nil, 11)
                dot:SetPoint("TOPLEFT", secCard, "TOPLEFT", 14, yoff)
                dot:SetText("+")
                Tint(dot, "text", "success")
            end
            SecLine("All sync data travels via private whispers, never party/raid/channel chat.", cy); cy = cy - 18
            SecLine("Validated by your Mesh Password; set a strong one to keep others out.", cy); cy = cy - 14
            secCard:SetContentHeight(math_abs(cy)); yPos = yPos - secCard:GetHeight() - 10

            local idCard = Card("Your identity", yPos)
            cy = -32
            FieldHeading(idCard, "Account Label", "(shown to other accounts on the network)", 14, cy); cy = cy - 16
            cy = (RC.UI:CreateHelpLine(idCard, 14, cy, "A short display name others will see when you sync. Keep it recognisable.", { gap = 6 }))
            local labelBox = self.UI:CreateStyledEditBox(idCard, {
                width=220, height=26, maxLetters=MAX_LABEL_LEN, initialText=mcfg.accountLabel or "",
                onFocusLost=function(eb)
                    local v=(eb:GetText():match("^%s*(.-)%s*$") or ""):sub(1,MAX_LABEL_LEN)
                    mcfg.accountLabel=v; eb:SetText(v)
                end,
            })
            labelBox:SetPoint("TOPLEFT", idCard, "TOPLEFT", 14, cy); cy = cy - 36

            local saveIdBtn = self.UI:CreateStyledButton(idCard, RCL["Save Label"], 100, 26)
            saveIdBtn:SetPoint("TOPLEFT", idCard, "TOPLEFT", 14, cy)
            saveIdBtn:SetScript("OnClick", function()
                local lv=(labelBox.editBox:GetText():match("^%s*(.-)%s*$") or ""):sub(1,MAX_LABEL_LEN)
                mcfg.accountLabel = lv
                if lv == "" then RC:Print(RCL["Mesh: Label cannot be empty."]); return end
                RC:Print(RCL["Mesh: Label saved."])
                RC:ShowSidebarMeshSync(frame)
            end)
            cy = cy - 14
            idCard:SetContentHeight(math_abs(cy)); yPos = yPos - idCard:GetHeight() - 10

            local chanCard = Card("Discovery channel", yPos)
            cy = -32
            DimFS(chanCard,
                "All accounts join this channel; joiners auto-save to your roster, hidden from chat.", 14, cy); cy = cy - 22

            -- Channel state as its own line: joined = success, configured
            -- but not joined = warning, nothing set = disabled.
            local chanStatus, chanStatusKey
            if (mcfg.discoveryChannel or "") ~= "" and MS:IsChannelJoined() then
                chanStatus, chanStatusKey = RCL["Joined: "] .. mcfg.discoveryChannel, "success"
            elseif (mcfg.discoveryChannel or "") ~= "" then
                chanStatus, chanStatusKey = RCL["Configured but not yet joined"], "warning"
            else
                chanStatus, chanStatusKey = RCL["Not configured"], "disabled"
            end
            Tint(NormalFS(chanCard, chanStatus, 14, cy), "text", chanStatusKey); cy = cy - 22

            FieldHeading(chanCard, "Channel Name", "(same on ALL accounts)", 14, cy); cy = cy - 16
            cy = (RC.UI:CreateHelpLine(chanCard, 14, cy, "Minimum 16 characters.", { gap = 6 }))
            local chanNameBox = self.UI:CreateStyledEditBox(chanCard, {
                width=280, height=26, maxLetters=60, initialText=mcfg.discoveryChannel or "",
                onFocusLost=function(eb)
                    local v = eb:GetText():match("^%s*(.-)%s*$") or ""
                    mcfg.discoveryChannel = v; eb:SetText(v)
                end,
            })
            chanNameBox:SetPoint("TOPLEFT", chanCard, "TOPLEFT", 14, cy); cy = cy - 36

            FieldHeading(chanCard, "Mesh Password", "(must be identical on ALL accounts)", 14, cy); cy = cy - 16
            cy = (RC.UI:CreateHelpLine(chanCard, 14, cy, string_format("Acts as the channel join password AND signs every sync message. Any message with the wrong password is silently dropped. Minimum %d characters.", MIN_PASS_LEN), { gap = 6 }))

            local realPassword = mcfg.meshPassword or ""
            local passVisible  = false
            local MASK_LEN     = 12

            local function SavePassword(v)
                if #v >= MIN_PASS_LEN then
                    realPassword      = v
                    mcfg.meshPassword = v
                end
            end

            local boxPlain = self.UI:CreateStyledEditBox(chanCard, {
                width=220, height=26, maxLetters=60, initialText="",
                onTextChanged=function(eb) if passVisible then realPassword = eb:GetText() end end,
                onFocusLost  =function(eb) if passVisible then SavePassword(eb:GetText()) end end,
            })
            boxPlain:SetPoint("TOPLEFT", chanCard, "TOPLEFT", 14, cy)
            boxPlain.editBox:SetText(realPassword)
            boxPlain.editBox:HookScript("OnEditFocusGained", function(eb) eb:HighlightText() end)
            boxPlain:Hide()

            local boxMasked = self.UI:CreateStyledEditBox(chanCard, {
                width=220, height=26, maxLetters=60, initialText="",
            })
            boxMasked:SetPoint("TOPLEFT", chanCard, "TOPLEFT", 14, cy)
            boxMasked:EnableMouse(false)
            boxMasked.editBox:EnableMouse(false)
            boxMasked.editBox:SetAutoFocus(false)

            local showPassBtn = self.UI:CreateStyledButton(chanCard, RCL["Show"], 50, 26)
            showPassBtn:SetPoint("LEFT", boxMasked, "RIGHT", 6, 0)

            local function RefreshPassDisplay()
                if passVisible then
                    boxPlain.editBox:SetText(realPassword);  boxPlain:Show();  boxMasked:Hide()
                else
                    boxMasked.editBox:SetText(realPassword ~= "" and string.rep("*", MASK_LEN) or "")
                    boxMasked.editBox:ClearFocus()
                    boxMasked:Show(); boxPlain:Hide()
                end
                showPassBtn.text:SetText(passVisible and RCL["Hide"] or RCL["Show"])
            end
            showPassBtn:SetScript("OnClick", function()
                if passVisible then realPassword = boxPlain.editBox:GetText() end
                passVisible  = not passVisible
                RefreshPassDisplay()
            end)
            RefreshPassDisplay()
            cy = cy - 36

            local applyChanBtn = self.UI:CreateStyledButton(chanCard, RCL["Apply Channel"], 110, 26)
            applyChanBtn:SetPoint("TOPLEFT", chanCard, "TOPLEFT", 14, cy)
            applyChanBtn:SetScript("OnClick", function()
                local cv = chanNameBox.editBox:GetText():match("^%s*(.-)%s*$") or ""
                local pv = passVisible and boxPlain.editBox:GetText() or realPassword
                if cv ~= "" and #cv < 16 then
                    RC:Print(RCL["Mesh: Channel Name must be 16+ characters."]); return
                end
                if #pv < MIN_PASS_LEN then
                    RC:Print(string_format("Mesh: Password must be %d+ characters.", MIN_PASS_LEN)); return
                end
                local old = mcfg.discoveryChannel or ""
                mcfg.discoveryChannel = cv
                mcfg.meshPassword     = pv
                if MS:IsEnabled() then
                    if cv ~= "" then MS:JoinDiscoveryChannel()
                    elseif old ~= "" and LeaveChannelByName then LeaveChannelByName(old) end
                end
                RC:Print(cv ~= "" and ("Mesh: Channel set - password saved.")
                                   or  RCL["Mesh: Discovery channel cleared."])
                RC:ShowSidebarMeshSync(frame)
            end)
            local clearChanBtn = self.UI:CreateStyledButton(chanCard, RCL["Clear Channel"], 110, 26)
            clearChanBtn:SetPoint("LEFT", applyChanBtn, "RIGHT", 6, 0)
            clearChanBtn:SetScript("OnClick", function()
                local old = mcfg.discoveryChannel or ""
                if old ~= "" then MS:LeaveDiscoveryChannel() end
                mcfg.discoveryChannel = ""
                RC:Print(RCL["Mesh: Discovery channel cleared."])
                RC:ShowSidebarMeshSync(frame)
            end)
            cy = cy - 14
            chanCard:SetContentHeight(math_abs(cy)); yPos = yPos - chanCard:GetHeight() - 10

            local membCard = Card("Known members  (auto-populated by discovery)", yPos)
            cy = -32
            cy = (RC.UI:CreateHelpLine(membCard, 14, cy, "Auto-populated via the channel, kept between sessions. Add one manually below if needed.", { gap = 6 }))

            local members = mcfg.members or {}
            if #members == 0 then
                cy = (RC.UI:CreateHelpLine(membCard, 14, cy, "No members yet. Add them below.", { gap = 6 }))
            else
                for i, member in ipairs(members) do
                    -- Account label in the accent, character name plain.
                    RunFS(membCard, 14, cy, 11, {
                        { member.label or "?", "ui", "accentGold" },
                        { "  " .. (member.name or ""), "text", "normal" },
                    })
                    local removeBtn = self.UI:CreateStyledButton(membCard, RCL["Remove"], 70, 22)
                    removeBtn:SetPoint("TOPRIGHT", membCard, "TOPRIGHT", -14, cy)
                    local idx = i
                    local memberTag = (member.label or "?") .. "  " .. (member.name or "")
                    removeBtn:SetScript("OnClick", function()
                        RC.UI:CreateConfirmDialog(RCL["Remove Member"],
                            RCL["Remove "] .. memberTag .. RCL[" from your roster?\n\nThey are added again automatically the next time they join the discovery channel."],
                            function()
                                table.remove(mcfg.members, idx)
                                RC:ShowSidebarMeshSync(frame)
                            end,
                            nil, RCL["Remove"], true)
                    end)
                    cy = cy - 24
                end
            end

            cy = cy - 8
            GoldFS(membCard, "Add Member", 14, cy); cy = cy - 18

            local function ShortLabel(parent, text, ax, ay)
                local fs = RC:CreateFontString(parent, "OVERLAY", nil, 10)
                fs:SetPoint("TOPLEFT", parent, "TOPLEFT", ax, ay)
                fs:SetText(text)
                Tint(fs, "text", "gray")
                return fs
            end

            ShortLabel(membCard, "Character name:", 14, cy)
            local newNameBox = self.UI:CreateStyledEditBox(membCard, {
                width=220, height=26, maxLetters=60, initialText="",
            })
            newNameBox:SetPoint("TOPLEFT", membCard, "TOPLEFT", 120, cy); cy = cy - 30

            ShortLabel(membCard, "Display label:", 14, cy)
            local newLabelBox = self.UI:CreateStyledEditBox(membCard, {
                width=180, height=26, maxLetters=MAX_LABEL_LEN, initialText="",
            })
            newLabelBox:SetPoint("TOPLEFT", membCard, "TOPLEFT", 120, cy); cy = cy - 30

            local addBtn = self.UI:CreateStyledButton(membCard, RCL["Add Member"], 110, 28)
            addBtn:SetPoint("TOPLEFT", membCard, "TOPLEFT", 14, cy)
            addBtn:SetScript("OnClick", function()
                local nameVal  = newNameBox.editBox:GetText():match("^%s*(.-)%s*$") or ""
                local labelVal = newLabelBox.editBox:GetText():match("^%s*(.-)%s*$") or ""
                if nameVal == "" then
                    RC:Print(RCL["Mesh: Enter a character name."]); return
                end
                if labelVal == "" then labelVal = nameVal:match("^([^%-]+)") or nameVal end
                if not mcfg.members then mcfg.members = {} end
                mcfg.members[#mcfg.members + 1] = { name = nameVal, label = labelVal }
                RC:Print(RCL["Mesh: Added "] .. nameVal)
                RC:ShowSidebarMeshSync(frame)
            end)
            cy = cy - 34
            cy = (RC.UI:CreateHelpLine(membCard, 14, cy, "Tip: this also reaches your OWN opposite-faction toon on the same Battle.net (add by Name-Realm) - the full mesh sync, at any distance, as long as both accounts use the same Mesh Password.", { gap = 6 }))
            membCard:SetContentHeight(math_abs(cy)); yPos = yPos - membCard:GetHeight() - 10

            -- This card mixes scopes: autoBroadcast is per-character
            -- (charCfg), while crossFaction below is account-wide (mcfg) -
            -- toggling one does not follow the other despite sharing a card.
            local abCard = Card("Live sync", yPos)
            cy = -32
            local abOn = (charCfg.autoBroadcast == true)
            local abCb = self.UI:CreateCheckbox(abCard, RCL["Auto-sync enabled categories when changes are saved"], abOn)
            abCb:SetPoint("TOPLEFT", abCard, "TOPLEFT", 14, cy)
            abCb:SetScript("OnClick", function()
                charCfg.autoBroadcast = abCb:GetChecked()
                self:ForceCheckboxUpdate(abCb, charCfg.autoBroadcast)
            end)
            cy = cy - 20
            cy = (RC.UI:CreateHelpLine(abCard, 14, cy, "Syncs ~1.5 seconds after you stop making changes. Only categories enabled in Sync Rules are sent.", { gap = 6 }))
            local xfOn = (mcfg.crossFaction ~= false)
            local xfCb = self.UI:CreateCheckbox(abCard, RCL["Cross-faction world buffs to a separate Battle.net"], xfOn)
            xfCb:SetPoint("TOPLEFT", abCard, "TOPLEFT", 14, cy)
            xfCb:SetScript("OnClick", function()
                mcfg.crossFaction = xfCb:GetChecked()
                self:ForceCheckboxUpdate(xfCb, mcfg.crossFaction)
            end)
            cy = cy - 20
            cy = (RC.UI:CreateHelpLine(abCard, 14, cy, "For a friend on a SEPARATE Battle.net (add their BattleTag below) - world buffs only. Your own toons on THIS Battle.net sync through Members instead, which carries the full mesh sync. Both sides always need the same Mesh Password.", { gap = 6 }))
            abCard:SetContentHeight(math_abs(cy)); yPos = yPos - abCard:GetHeight() - 10

            local xfCard = Card("Cross-faction peers", yPos)
            cy = -32
            mcfg.crossFactionPeers = mcfg.crossFactionPeers or {}
            local peerTags = {}
            for tag in pairs(mcfg.crossFactionPeers) do peerTags[#peerTags + 1] = tag end
            table.sort(peerTags)
            if #peerTags == 0 then
                cy = (RC.UI:CreateHelpLine(xfCard, 14, cy, "No cross-faction peers yet. Add a friend's BattleTag below to sync world buffs across factions.", { gap = 6 }))
            else
                for _, tag in ipairs(peerTags) do
                    NormalFS(xfCard, tag, 14, cy)
                    local rmBtn = self.UI:CreateStyledButton(xfCard, RCL["Remove"], 70, 22)
                    rmBtn:SetPoint("TOPRIGHT", xfCard, "TOPRIGHT", -14, cy)
                    local t = tag
                    rmBtn:SetScript("OnClick", function()
                        RC.UI:CreateConfirmDialog(RCL["Remove Peer"],
                            RCL["Remove "] .. t .. RCL[" from your cross-faction peers?"],
                            function()
                                mcfg.crossFactionPeers[t] = nil
                                RC:ShowSidebarMeshSync(frame)
                            end,
                            nil, RCL["Remove"], true)
                    end)
                    cy = cy - 24
                end
            end

            cy = cy - 8
            GoldFS(xfCard, "Add Peer", 14, cy); cy = cy - 18

            local tagFS = RC:CreateFontString(xfCard, "OVERLAY", nil, 10)
            tagFS:SetPoint("TOPLEFT", xfCard, "TOPLEFT", 14, cy)
            tagFS:SetText(RCL["BattleTag:"])
            Tint(tagFS, "text", "gray")
            local tagBox = self.UI:CreateStyledEditBox(xfCard, {
                width=200, height=26, maxLetters=64, initialText="",
            })
            tagBox:SetPoint("TOPLEFT", xfCard, "TOPLEFT", 120, cy); cy = cy - 32

            local addTagBtn = self.UI:CreateStyledButton(xfCard, RCL["Add Peer"], 110, 28)
            addTagBtn:SetPoint("TOPLEFT", xfCard, "TOPLEFT", 14, cy)
            addTagBtn:SetScript("OnClick", function()
                local tagVal = tagBox.editBox:GetText():match("^%s*(.-)%s*$") or ""
                if tagVal == "" then
                    RC:Print(RCL["Mesh: Enter a BattleTag, e.g. Name#1234."]); return
                end
                if not string.find(tagVal, "#") then
                    RC:Print(RCL["Mesh: That doesn't look like a BattleTag - include the number, e.g. Name#1234."]); return
                end
                mcfg.crossFactionPeers[tagVal] = true
                RC:Print(RCL["Mesh: Added cross-faction peer "] .. tagVal)
                RC:ShowSidebarMeshSync(frame)
            end)
            cy = cy - 34

            cy = (RC.UI:CreateHelpLine(xfCard, 14, cy, "Whispered to these Battle.net accounts over any distance, crossing factions (hidden from chat). Use a BattleTag like Name#1234.", { gap = 6 }))
            Tint(NormalFS(xfCard, "This is for a friend on a DIFFERENT Battle.net than yours.", 14, cy), "text", "warning"); cy = cy - 16
            NormalFS(xfCard, "To sync your OWN opposite-faction toons on the SAME Battle.net, add them in Members above by Name-Realm instead - that crosses factions at any distance and syncs everything, not just world buffs.", 14, cy); cy = cy - 48
            xfCard:SetContentHeight(math_abs(cy)); yPos = yPos - xfCard:GetHeight() - 10

        elseif activeTab == "sync" then

            -- Offsets anchor to each row's right edge (rows span the card),
            -- so the Send/Receive checkboxes and the Only link stay
            -- column-aligned under the ColumnHeaders on every card.
            local SEND_CB_X  = -104
            local RECV_CB_X  = -46
            local SOLO_BTN_X = -150
            local LABEL_CAP  = -158
            local ROW_H      = 20

            if not (charCfg and charCfg.autoBroadcast == true) then
                local warnCard = Card("Live sync is OFF for this character", yPos)
                local wy = -32
                DimFS(warnCard, "The rules below still apply at login and to manual pushes, but changes will NOT broadcast to your members live as you make them.", 14, wy); wy = wy - 32
                local fixBtn = self.UI:CreateStyledButton(warnCard, RCL["Enable Live Sync"], 130, 24)
                fixBtn:SetPoint("TOPLEFT", warnCard, "TOPLEFT", 14, wy)
                fixBtn:SetScript("OnClick", function()
                    charCfg.autoBroadcast = true
                    RC:ShowSidebarMeshSync(frame)
                end)
                wy = wy - 32
                warnCard:SetContentHeight(math_abs(wy))
                yPos = yPos - warnCard:GetHeight() - 12
            end

            -- Forward declarations: the presets and every row call back
            -- into these after a change, so the whole tab repaints from
            -- the model without a rebuild (which would drop the search
            -- text and churn hundreds of frames).
            local RefreshStates, RefreshSummary, Relayout

            -- What this character is actually broadcasting right now. Without
            -- this readout an all-off Send set looks identical to a working
            -- mesh: members connect, nothing ever arrives, nothing explains why.
            local presetCard = Card("Quick presets", yPos)
            local py = -32

            -- Three runs (lead / count / tail) plus a second line, all
            -- re-textable so RefreshSummary can update them in place.
            local sumLead = RC:CreateFontString(presetCard, "OVERLAY", nil, 11)
            sumLead:SetPoint("TOPLEFT", presetCard, "TOPLEFT", 14, py)
            sumLead:SetJustifyH("LEFT"); sumLead:SetWordWrap(false)
            local sumCount = RC:CreateFontString(presetCard, "OVERLAY", nil, 11)
            sumCount:SetPoint("LEFT", sumLead, "RIGHT", 0, 0)
            sumCount:SetJustifyH("LEFT"); sumCount:SetWordWrap(false)
            local sumTail = RC:CreateFontString(presetCard, "OVERLAY", nil, 11)
            sumTail:SetPoint("LEFT", sumCount, "RIGHT", 0, 0)
            sumTail:SetPoint("RIGHT", presetCard, "RIGHT", -14, 0)
            sumTail:SetJustifyH("LEFT"); sumTail:SetWordWrap(false)
            py = py - 16
            local sumLine2 = NormalFS(presetCard, "", 14, py)
            sumLine2:SetWordWrap(false)
            py = py - 18
            local sumRecv = DimFS(presetCard, "", 14, py)
            py = py - 24

            RefreshSummary = function()
                local sendOn, catTotal = MS:CountSendCategories()
                local recvOn           = MS:CountRecvCategories()
                if sendOn == 0 then
                    sumLead:SetText(RCL["This character is sending nothing."])
                    Tint(sumLead, "text", "red")
                    sumCount:SetText(""); sumTail:SetText("")
                    sumLine2:SetText(RCL["Every setting below has Send unticked - members get nothing from this character."])
                else
                    local labels = MS:GetSendCategoryLabels()
                    local summary
                    if sendOn <= 4 then
                        summary = table.concat(labels, ", ")
                    else
                        summary = table.concat({labels[1], labels[2], labels[3]}, ", ")
                            .. " +" .. (sendOn - 3) .. " more"
                    end
                    sumLead:SetText(RCL["Sending "])
                    Tint(sumLead, "text", "normal")
                    sumCount:SetText(tostring(sendOn))
                    Tint(sumCount, "text", "success")
                    sumTail:SetText(string_format(" of %d categories: %s", catTotal, summary))
                    Tint(sumTail, "text", "normal")
                    sumLine2:SetText("")
                end
                sumRecv:SetText(string_format("Receiving %d of %d categories.", recvOn, catTotal))
            end

            local function PresetBtn(label, width, xOff, yOff, onClick)
                local b = self.UI:CreateStyledButton(presetCard, label, width, 24)
                b:SetPoint("TOPLEFT", presetCard, "TOPLEFT", xOff, yOff)
                b:SetScript("OnClick", function()
                    onClick()
                    RefreshStates()
                end)
                -- Hooked, not set: the styled button owns its hover paint.
                b:HookScript("OnEnter", function(btn)
                    local tc = RC:GetColor("text", "gray")
                    GameTooltip:SetOwner(btn, "ANCHOR_TOP")
                    GameTooltip:SetText(RCL["Applies to every feature, not just this tab"], tc.r, tc.g, tc.b, 1, true)
                    GameTooltip:Show()
                end)
                b:HookScript("OnLeave", function() GameTooltip:Hide() end)
                return b
            end

            -- Presets set every per-setting state too, not just the
            -- category flags (MS:SetAll*Categories clears the exclusion
            -- lists), so the list below reads exactly as the button says.
            PresetBtn(RCL["Send: None"], 110, 14, py, function()
                MS:SetAllSendCategories(false)
                RC:Print(RCL["Mesh: Send cleared - this character now broadcasts nothing."])
            end)
            PresetBtn(RCL["Send: All"], 115, 130, py, function()
                local n = MS:SetAllSendCategories(true)
                RC:Print(RCL["Mesh: Send enabled for every setting in all "] .. n .. RCL[" categories."])
            end)
            py = py - 30

            PresetBtn(RCL["Receive: All"], 110, 14, py, function()
                MS:SetAllRecvCategories(true)
            end)
            PresetBtn(RCL["Receive: None"], 115, 130, py, function()
                MS:SetAllRecvCategories(false)
                RC:Print(RCL["Mesh: Receive cleared - this character now applies nothing from the mesh."])
            end)
            py = py - 32

            RunFS(presetCard, 14, py, 10, {
                { RCL["To sync one thing only, hit Send: None then use the "], "text", "gray" },
                { RCL["Only"], "ui", "accentGold" },
                { RCL[" link on the row you want."], "text", "gray" },
            }, -14)
            py = py - 22
            presetCard:SetContentHeight(math_abs(py))
            yPos = yPos - presetCard:GetHeight() - 12

            -- Legend: keyword in the accent, explanation in gray.
            local function Legend(keyword, explanation)
                RunFS(parent, 18, yPos, 10, {
                    { keyword, "ui", "accentGold" },
                    { " " .. explanation, "text", "gray" },
                }, -18)
            end
            Legend(RCL["Send"],    RCL["broadcasts that setting from this character to your members."]); yPos = yPos - 14
            Legend(RCL["Receive"], RCL["applies that setting when a member sends it - untick to protect it on this character."]); yPos = yPos - 14
            Legend(RCL["Only"],    RCL["makes that row the single thing this character sends."]); yPos = yPos - 22

            -- Feature groups, in card order. Computed here because the tab
            -- strip below needs the list before the cards are built.
            local GROUP_ORDER = { "Raids", "Reminders", "Combat", "Equipment", "Consumables", "Display & UI" }
            local groupCats, groupSeen, groupList = {}, {}, {}
            for _, g in ipairs(GROUP_ORDER) do
                groupCats[g] = {}; groupSeen[g] = true; groupList[#groupList + 1] = g
            end
            for _, cat in ipairs(cats) do
                if not MS.IsCategoryVisible or MS.IsCategoryVisible(cat) then
                    local g = cat.group or "Other"
                    if not groupSeen[g] then
                        groupCats[g] = {}; groupSeen[g] = true; groupList[#groupList + 1] = g
                    end
                    groupCats[g][#groupCats[g] + 1] = cat
                end
            end

            -- One tab per feature group plus "All". Opens on the first real
            -- group so the page starts short; "All" is the long list. A
            -- live search overrides the tab (see Relayout) and the strip
            -- shows "All" while it does.
            local ALL_TAB = "All"
            local tabDefs = { { key = ALL_TAB, label = RCL["All"] } }
            local firstGroup = nil
            for _, g in ipairs(groupList) do
                if #groupCats[g] > 0 then
                    tabDefs[#tabDefs + 1] = { key = g, label = g }
                    firstGroup = firstGroup or g
                end
            end
            if not frame.syncRulesGroupTab or (frame.syncRulesGroupTab ~= ALL_TAB
                    and not (groupCats[frame.syncRulesGroupTab] and #groupCats[frame.syncRulesGroupTab] > 0)) then
                frame.syncRulesGroupTab = firstGroup or ALL_TAB
            end
            -- Both declared ahead so the tab strip's onClick and Relayout
            -- close over the locals, not globals of the same name.
            local searchBox, tabGroup
            local tabY
            tabGroup, tabY = self.UI:CreateTabGroup(parent, {
                y = yPos, inset = 18, advance = 32,
                tabs = tabDefs,
                selected = (frame._meshRuleSearch or "") ~= "" and ALL_TAB or frame.syncRulesGroupTab,
                onClick = function(key)
                    frame.syncRulesGroupTab = key
                    frame._syncRulesTabBeforeSearch = nil
                    if tabGroup then tabGroup:SetSelected(key) end
                    -- Picking a tab while a search is live means "show me
                    -- this group": drop the query (ClearSearch relayouts).
                    if searchBox and searchBox:GetSearchText() ~= "" then
                        searchBox:ClearSearch()
                    else
                        Relayout()
                    end
                end,
            })
            yPos = tabY

            -- Search box + live "shown" count. The text survives clicks
            -- because nothing below rebuilds; it is also remembered on the
            -- frame so a tab switch and back keeps the filter. A non-empty
            -- query searches EVERY group, whatever tab is selected.
            searchBox = self.UI:CreateSearchBox(parent, {
                placeholder = RCL["Find a setting..."],
                width = 260, height = 22, maxLetters = 60,
                initialText = frame._meshRuleSearch or "",
                onChange = function(txt)
                    frame._meshRuleSearch = txt
                    Relayout()
                end,
            })
            searchBox:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yPos)
            local shownFS = RC:CreateFontString(parent, "OVERLAY", nil, 10)
            -- by its top on both ends (a RIGHT-to-RIGHT anchor would also
            -- pull it to the middle of the page)
            shownFS:SetPoint("TOPLEFT", searchBox, "TOPRIGHT", 10, -6)
            shownFS:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -18, yPos - 6)
            shownFS:SetJustifyH("LEFT")
            Tint(shownFS, "text", "gray")
            yPos = yPos - 30

            local noMatchFS = DimFS(parent, RCL["No setting matches that search."], 18, yPos)
            noMatchFS:Hide()
            local listTop = yPos

            -- Real names from the settings registry ("Ability ready grace
            -- period", not a guess at abilityReadyGracePeriod).
            local function Label(path)
                if RC.GetSettingLabel then return RC:GetSettingLabel(path) end
                local leaf = path:match("([^%.]+)$") or path
                local s = leaf:gsub("(%l)(%u)", "%1 %2"):gsub("(%u)(%u%l)", "%1 %2")
                return s:sub(1, 1):upper() .. s:sub(2)
            end

            local function ColumnHeaders(card)
                local sfs = RC:CreateFontString(card, "OVERLAY", nil, 10)
                sfs:SetPoint("TOPLEFT", card, "TOPRIGHT", SEND_CB_X - 6, -12)
                sfs:SetText(RCL["Send"])
                Tint(sfs, "text", "gray")
                local rfs = RC:CreateFontString(card, "OVERLAY", nil, 10)
                rfs:SetPoint("TOPLEFT", card, "TOPRIGHT", RECV_CB_X - 12, -12)
                rfs:SetText(RCL["Receive"])
                Tint(rfs, "text", "gray")
                local ofs = RC:CreateFontString(card, "OVERLAY", nil, 10)
                ofs:SetPoint("TOPLEFT", card, "TOPRIGHT", SOLO_BTN_X + 2, -12)
                ofs:SetText(RCL["Only"])
                Tint(ofs, "text", "gray")
            end

            -- One 20px row spanning the card. Positioned by Relayout.
            local function NewRow(card, tooltipTitle, tooltipPath)
                local row = CreateFrame("Frame", nil, card)
                row:SetHeight(ROW_H)
                if tooltipPath then
                    -- Hover only shows the raw path (handy when searching
                    -- by it); the frame has no fill, so the colour swap is
                    -- a no-op and the helper just owns the scripts.
                    local clear = { r = 0, g = 0, b = 0, a = 0 }
                    row:EnableMouse(true)
                    self.UI:AttachHover(row, clear, clear, {
                        onEnter = function(r)
                            local tc = RC:GetColor("text", "gold")
                            local pc = RC:GetColor("text", "gray")
                            GameTooltip:SetOwner(r, "ANCHOR_LEFT")
                            GameTooltip:SetText(tooltipTitle, tc.r, tc.g, tc.b)
                            GameTooltip:AddLine(tooltipPath, pc.r, pc.g, pc.b, true)
                            GameTooltip:Show()
                        end,
                        onLeave = function() GameTooltip:Hide() end,
                    })
                end
                return row
            end

            local function RowCheckbox(row, x)
                local cb = self.UI:CreateCheckbox(row, "", false)
                cb:ClearAllPoints()
                cb:SetPoint("LEFT", row, "RIGHT", x, 0)
                return cb
            end

            local function RowOnly(row, fontSize)
                local b = self.UI:CreateLinkButton(row, RCL["Only"], fontSize or 9)
                b:SetPoint("LEFT", row, "RIGHT", SOLO_BTN_X, 0)
                return b
            end

            -- Category header: label, "(send n/m · receive n/m)" when
            -- partial, Send/Receive that flip the whole category, Only.
            local function CategoryRow(card, cat)
                local id = cat.id
                local label = cat.label or id
                local row = NewRow(card, label, id)
                local lfs = RC:CreateFontString(row, "OVERLAY", nil, 11)
                lfs:SetPoint("LEFT", row, "LEFT", 14, 0)
                lfs:SetJustifyH("LEFT")
                lfs:SetWordWrap(false)
                lfs:SetText(label)
                Tint(lfs, "text", "normal")
                local cfs = RC:CreateFontString(row, "OVERLAY", nil, 10)
                cfs:SetPoint("RIGHT", row, "RIGHT", LABEL_CAP, 0)
                cfs:SetJustifyH("RIGHT")
                cfs:SetWordWrap(false)
                Tint(cfs, "ui", "accentGold")
                lfs:SetPoint("RIGHT", cfs, "LEFT", -6, 0)

                local solo = RowOnly(row, 10)
                solo:SetScript("OnClick", function()
                    MS:SoloSendCategoryAll(id)
                    RC:Print(RCL["Mesh: Now sending only: "] .. label)
                    RefreshStates()
                end)
                local sCb = RowCheckbox(row, SEND_CB_X)
                sCb:SetScript("OnClick", function()
                    local on, tot = MS:CountSendState(id)
                    local allOn = (tot > 0 and on == tot)
                        or (tot == 0 and charCfg.syncCategories[id] == true)
                    MS:SetCategorySendAll(id, not allOn)
                    RefreshStates()
                end)
                local rCb = RowCheckbox(row, RECV_CB_X)
                rCb:SetScript("OnClick", function()
                    local on, tot = MS:CountRecvState(id)
                    local rc = charCfg.recvCategories
                    local allOn = (tot > 0 and on == tot)
                        or (tot == 0 and not (rc and rc[id] == false))
                    MS:SetCategoryRecvAll(id, not allOn)
                    RefreshStates()
                end)
                return {
                    frame = row, kind = "cat", catId = id, label = label,
                    search = string.lower(label .. " " .. id),
                    sendCb = sCb, recvCb = rCb, countFS = cfs, labelFS = lfs,
                }
            end

            -- One field group of a feature ("Position & Lock", ...): its
            -- own Send, Receive and Only, driving every setting it covers.
            -- The hover tooltip names those settings so nothing is hidden.
            local function GroupRow(card, catId, grp, indent)
                local covered, searchParts = {}, { string.lower(grp.label) }
                for _, p in ipairs(grp.paths) do
                    local l = Label(p)
                    covered[#covered + 1] = l
                    searchParts[#searchParts + 1] = string.lower(l .. " " .. p)
                end
                table_sort(covered)
                local coveredText = table.concat(covered, ", ")
                local row = NewRow(card, grp.label, coveredText)
                local lfs = RC:CreateFontString(row, "OVERLAY", nil, 10)
                lfs:SetPoint("LEFT", row, "LEFT", indent, 0)
                lfs:SetJustifyH("LEFT")
                lfs:SetWordWrap(false)
                lfs:SetText(grp.label)
                Tint(lfs, "text", "gray")
                local cfs = RC:CreateFontString(row, "OVERLAY", nil, 10)
                cfs:SetPoint("RIGHT", row, "RIGHT", LABEL_CAP, 0)
                cfs:SetJustifyH("RIGHT")
                cfs:SetWordWrap(false)
                Tint(cfs, "ui", "accentGold")
                lfs:SetPoint("RIGHT", cfs, "LEFT", -6, 0)

                local paths = grp.paths
                local solo = RowOnly(row, 9)
                solo:SetScript("OnClick", function()
                    MS:SoloSendKeys(catId, paths)
                    RC:Print(RCL["Mesh: Now sending only: "] .. grp.label
                        .. " (" .. coveredText .. ")")
                    RefreshStates()
                end)
                local sCb = RowCheckbox(row, SEND_CB_X)
                sCb:SetScript("OnClick", function()
                    MS:SetKeysSendState(catId, paths, sCb:GetChecked() and true or false)
                    RefreshStates()
                end)
                local rCb = RowCheckbox(row, RECV_CB_X)
                rCb:SetScript("OnClick", function()
                    MS:SetKeysRecvState(catId, paths, rCb:GetChecked() and true or false)
                    RefreshStates()
                end)
                return {
                    frame = row, kind = "group", catId = catId, paths = paths,
                    label = grp.label, search = table.concat(searchParts, " "),
                    sendCb = sCb, recvCb = rCb, countFS = cfs, labelFS = lfs,
                }
            end

            -- ---- Build: one card per settings group, every feature as a
            -- header with at most one row per field group underneath. ----
            local cards = {}
            local totalSettings, totalFeatures = 0, 0
            for _, g in ipairs(groupList) do
                local catList = groupCats[g]
                if #catList > 0 then
                    local card = Card(g, listTop)
                    ColumnHeaders(card)
                    local rec = { frame = card, groupName = g, blocks = {} }
                    for _, cat in ipairs(catList) do
                        local block = { catId = cat.id, header = CategoryRow(card, cat), rows = {} }
                        local settings = MS:GetCategorySettings(cat.id)
                        totalSettings = totalSettings + #settings
                        totalFeatures = totalFeatures + 1
                        -- A feature that is one lone setting is fully
                        -- described by its header row.
                        local lone = (#settings == 1 and settings[1].depth == 0)
                        if not lone then
                            for _, grp in ipairs(MS:GetCategoryGroups(cat.id)) do
                                block.rows[#block.rows + 1] = GroupRow(card, cat.id, grp, 28)
                            end
                        end
                        rec.blocks[#rec.blocks + 1] = block
                    end
                    cards[#cards + 1] = rec
                end
            end

            -- "(send n/m - receive n/m)" for a partially-on row, else "".
            local function PartialText(sOn, sTot, rOn, rTot)
                local parts = {}
                if sTot > 0 and sOn > 0 and sOn < sTot then
                    parts[#parts + 1] = RCL["send "] .. sOn .. "/" .. sTot
                end
                if rTot > 0 and rOn > 0 and rOn < rTot then
                    parts[#parts + 1] = RCL["receive "] .. rOn .. "/" .. rTot
                end
                if #parts > 0 then return "(" .. table.concat(parts, " - ") .. ")" end
                return ""
            end

            -- ---- Repaint every checkbox / count from the model. ----
            RefreshStates = function()
                for _, rec in ipairs(cards) do
                    for _, block in ipairs(rec.blocks) do
                        local id = block.catId
                        local sOn, sTot = MS:CountSendState(id)
                        local rOn, rTot = MS:CountRecvState(id)
                        local h = block.header
                        local sAll = (sTot > 0 and sOn == sTot)
                            or (sTot == 0 and charCfg.syncCategories[id] == true)
                        local rc = charCfg.recvCategories
                        local rAll = (rTot > 0 and rOn == rTot)
                            or (rTot == 0 and not (rc and rc[id] == false))
                        self:ForceCheckboxUpdate(h.sendCb, sAll)
                        self:ForceCheckboxUpdate(h.recvCb, rAll)
                        h.countFS:SetText(PartialText(sOn, sTot, rOn, rTot))
                        for _, r in ipairs(block.rows) do
                            local gsOn, gsTot = MS:CountSendStateFor(id, r.paths)
                            local grOn, grTot = MS:CountRecvStateFor(id, r.paths)
                            self:ForceCheckboxUpdate(r.sendCb, gsTot > 0 and gsOn == gsTot)
                            self:ForceCheckboxUpdate(r.recvCb, grTot > 0 and grOn == grTot)
                            r.countFS:SetText(PartialText(gsOn, gsTot, grOn, grTot))
                        end
                    end
                end
                RefreshSummary()
            end

            -- ---- Filter + stack. Search matches the feature label, a group
            -- label, or any covered setting's label or path; a feature hit
            -- shows all its rows, a row hit shows that row under its feature. ----
            Relayout = function()
                local q = string.lower((frame._meshRuleSearch or ""):match("^%s*(.-)%s*$") or "")
                local function hit(s) return q == "" or string.find(s, q, 1, true) ~= nil end
                -- A live query searches every group: the strip flips to
                -- "All" for the duration and the tab comes back when the
                -- box is cleared.
                local activeTab = frame.syncRulesGroupTab or ALL_TAB
                if q ~= "" then
                    if frame.syncRulesGroupTab ~= ALL_TAB and not frame._syncRulesTabBeforeSearch then
                        frame._syncRulesTabBeforeSearch = frame.syncRulesGroupTab
                    end
                    activeTab = ALL_TAB
                    if tabGroup then tabGroup:SetSelected(ALL_TAB) end
                elseif frame._syncRulesTabBeforeSearch then
                    frame.syncRulesGroupTab = frame._syncRulesTabBeforeSearch
                    frame._syncRulesTabBeforeSearch = nil
                    activeTab = frame.syncRulesGroupTab
                    if tabGroup then tabGroup:SetSelected(activeTab) end
                end
                local y = listTop
                local shown, anyCard = 0, false
                for _, rec in ipairs(cards) do
                    local card = rec.frame
                    local cy = -32
                    local cardVisible = false
                    local onTab = (activeTab == ALL_TAB) or (rec.groupName == activeTab)
                    for _, block in ipairs(rec.blocks) do
                        local catHit = hit(block.header.search)
                        local vis, anyRow = {}, false
                        for i, r in ipairs(block.rows) do
                            vis[i] = catHit or hit(r.search)
                            if vis[i] then anyRow = true end
                        end
                        if onTab and (catHit or anyRow) then
                            cardVisible = true
                            shown = shown + 1
                            block.header.frame:ClearAllPoints()
                            block.header.frame:SetPoint("TOPLEFT",  card, "TOPLEFT",  0, cy)
                            block.header.frame:SetPoint("TOPRIGHT", card, "TOPRIGHT", 0, cy)
                            block.header.frame:Show()
                            cy = cy - ROW_H
                            for i, r in ipairs(block.rows) do
                                if vis[i] then
                                    r.frame:ClearAllPoints()
                                    r.frame:SetPoint("TOPLEFT",  card, "TOPLEFT",  0, cy)
                                    r.frame:SetPoint("TOPRIGHT", card, "TOPRIGHT", 0, cy)
                                    r.frame:Show()
                                    cy = cy - ROW_H
                                else
                                    r.frame:Hide()
                                end
                            end
                            cy = cy - 6
                        else
                            block.header.frame:Hide()
                            for _, r in ipairs(block.rows) do r.frame:Hide() end
                        end
                    end
                    if cardVisible then
                        anyCard = true
                        card:ClearAllPoints()
                        card:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, y)
                        card:SetPoint("RIGHT",   parent, "RIGHT",  -18, 0)
                        card:SetContentHeight(math_abs(cy))
                        card:Show()
                        y = y - card:GetHeight() - 12
                    else
                        card:Hide()
                    end
                end
                if anyCard then
                    noMatchFS:Hide()
                else
                    noMatchFS:Show()
                    y = y - 24
                end
                if q ~= "" then
                    shownFS:SetText(string_format(RCL["%d of %d features match (all groups)"], shown, totalFeatures))
                elseif activeTab == ALL_TAB then
                    shownFS:SetText(string_format(RCL["%d features, %d settings"], totalFeatures, totalSettings))
                else
                    shownFS:SetText(string_format(RCL["%d of %d features on this tab"], shown, totalFeatures))
                end
                yPos = y
                self:UpdateSidebarScrollbar(self.sidebarConfigFrame, math_abs(y))
            end
            RefreshStates()
            Relayout()
        elseif activeTab == "network" then

            local afCard = Card("Accept data from", yPos)
            local cy = -32
            cy = (RC.UI:CreateHelpLine(afCard, 14, cy, "Which accounts this character applies mesh data from. Your own same-account characters always sync. Blocked pushes show in Recent Activity below.", { gap = 6 }))

            -- "priority" is not a stored recvFromMode value - it's inferred
            -- from priorityAccount being set (or _afPrioEditing mid-edit).
            -- Setting a priority account silently downgrades a prior
            -- "selected" mode back to "all" underneath it.
            local prioVal = charCfg.priorityAccount or ""
            if prioVal ~= "" and charCfg.recvFromMode == "selected" then
                charCfg.recvFromMode = "all"
            end
            local mode
            if prioVal ~= "" or frame._afPrioEditing then mode = "priority"
            elseif (charCfg.recvFromMode or "all") == "selected" then mode = "selected"
            else mode = "all" end

            local function SetAcceptMode(m)
                if m == "all" then
                    charCfg.recvFromMode    = "all"
                    charCfg.priorityAccount = ""
                    frame._afPrioEditing    = nil
                elseif m == "selected" then
                    charCfg.recvFromMode    = "selected"
                    charCfg.priorityAccount = ""
                    frame._afPrioEditing    = nil
                else
                    charCfg.recvFromMode = "all"
                    frame._afPrioEditing = true
                end
                RC:ShowSidebarMeshSync(frame)
            end

            -- State strings compared raw, never through RCL: "all" is a
            -- stored value, not display text, and a locale that translates
            -- the key would silently untick every radio here.
            local cbAll = self.UI:CreateCheckbox(afCard, RCL["Everyone on the mesh"], mode == "all")
            cbAll:SetPoint("TOPLEFT", afCard, "TOPLEFT", 14, cy)
            cbAll:SetScript("OnClick", function() SetAcceptMode("all") end)
            cy = cy - 22

            local cbSel = self.UI:CreateCheckbox(afCard, RCL["Only the accounts I pick below"], mode == "selected")
            cbSel:SetPoint("TOPLEFT", afCard, "TOPLEFT", 14, cy)
            cbSel:SetScript("OnClick", function() SetAcceptMode("selected") end)
            cy = cy - 22

            if mode == "selected" then
                charCfg.recvFromAccounts = charCfg.recvFromAccounts or {}
                local allow = charCfg.recvFromAccounts
                local labelSet = {}
                for _, m in ipairs(MS:GetMembers()) do
                    if m.label and m.label ~= "" then labelSet[m.label] = true end
                end
                for label in pairs(MS:GetKnownAccounts()) do labelSet[label] = true end
                for label in pairs(allow) do labelSet[label] = true end
                local labels = {}
                for label in pairs(labelSet) do labels[#labels+1] = label end
                table_sort(labels)
                if #labels == 0 then
                    cy = (RC.UI:CreateHelpLine(afCard, 32, cy, "No accounts known yet - they appear here once added in Setup or heard on the mesh.", { gap = 6 }))
                else
                    local anyOn = false
                    for _, label in ipairs(labels) do
                        if allow[label] == true then anyOn = true; break end
                    end
                    if not anyOn then
                        Tint(NormalFS(afCard, "Nothing selected - this character currently accepts mesh data from NO ONE.", 32, cy), "text", "warning"); cy = cy - 20
                    end
                    for _, label in ipairs(labels) do
                        local cb = self.UI:CreateCheckbox(afCard, label, allow[label] == true)
                        cb:SetPoint("TOPLEFT", afCard, "TOPLEFT", 32, cy)
                        local lbl = label
                        cb:SetScript("OnClick", function()
                            if cb:GetChecked() then allow[lbl] = true else allow[lbl] = nil end
                            self:ForceCheckboxUpdate(cb, allow[lbl] == true)
                        end)
                        cy = cy - 22
                    end
                end
                cy = cy - 4
            end

            local cbPrio = self.UI:CreateCheckbox(afCard, RCL["One priority account only"], mode == "priority")
            cbPrio:SetPoint("TOPLEFT", afCard, "TOPLEFT", 14, cy)
            cbPrio:SetScript("OnClick", function() SetAcceptMode("priority") end)
            cy = cy - 22

            if mode == "priority" then
                cy = (RC.UI:CreateHelpLine(afCard, 32, cy, "Only this account's pushes are auto-applied; everything else is logged and skipped.", { gap = 6 }))
                if prioVal ~= "" then
                    RunFS(afCard, 32, cy, 11, {
                        { RCL["Active:"], "text", "success" },
                        { RCL["  accepting only from "], "text", "normal" },
                        { prioVal, "ui", "accentGold" },
                    }, -14)
                else
                    Tint(NormalFS(afCard, "Pick the account below - until then, everyone is accepted.", 32, cy), "text", "warning")
                end
                cy = cy - 22

                local lbFS = RC:CreateFontString(afCard, "OVERLAY", nil, 11)
                lbFS:SetPoint("TOPLEFT", afCard, "TOPLEFT", 32, cy)
                lbFS:SetText(RCL["Label:"])
                Tint(lbFS, "text", "normal")
                local prioBox = self.UI:CreateStyledEditBox(afCard, {width=170, height=26, maxLetters=MAX_LABEL_LEN, initialText=prioVal})
                prioBox:SetPoint("TOPLEFT", afCard, "TOPLEFT", 75, cy)
                local prioSet = self.UI:CreateStyledButton(afCard, RCL["Set Priority"], 110, 26)
                prioSet:SetPoint("LEFT", prioBox, "RIGHT", 6, 0)
                prioSet:SetScript("OnClick", function()
                    local v = (prioBox.editBox:GetText():match("^%s*(.-)%s*$") or ""):sub(1, MAX_LABEL_LEN)
                    charCfg.priorityAccount = v
                    if v ~= "" then frame._afPrioEditing = nil end
                    RC:ShowSidebarMeshSync(frame)
                end)
                cy = cy - 34

                local qNames = {}
                for label in pairs(MS:GetKnownAccounts()) do qNames[#qNames+1] = label end
                table_sort(qNames)
                if #qNames > 0 then
                    DimFS(afCard, "Quick-set:", 32, cy)
                    local qx = 99
                    for _, label in ipairs(qNames) do
                        if qx > 560 then break end
                        local qBtn = self.UI:CreateStyledButton(afCard, label, 110, 22)
                        qBtn:SetPoint("TOPLEFT", afCard, "TOPLEFT", qx, cy)
                        local lbl = label
                        qBtn:SetScript("OnClick", function()
                            charCfg.priorityAccount = lbl
                            frame._afPrioEditing = nil
                            RC:ShowSidebarMeshSync(frame)
                        end)
                        qx = qx + 116
                    end
                    cy = cy - 28
                end
            end
            cy = cy - 4
            afCard:SetContentHeight(math_abs(cy)); yPos = yPos - afCard:GetHeight() - 10

            local acctCard = Card("Members", yPos)
            cy = -32
            local now  = GetTime()
            local known = MS:GetKnownAccounts()
            local members = MS:GetMembers()
            if #members == 0 then
                cy = (RC.UI:CreateHelpLine(acctCard, 14, cy, "No members configured. Add them in the Setup tab.", { gap = 6 }))
            else
                for _, member in ipairs(members) do
                    local info    = known[member.label]
                    local online  = info and info.online
                    local _dc = online and RC:GetColor("ui", "configured") or RC:GetColor("raids", "disabled")
                    Dot(acctCard, _dc.r, _dc.g, _dc.b, 14, cy+2)
                    -- Label in the accent, name plain; offline members dim.
                    if online then
                        RunFS(acctCard, 28, cy, 11, {
                            { member.label or "?", "ui", "accentGold" },
                            { "  " .. (member.name or ""), "text", "normal" },
                        })
                    else
                        RunFS(acctCard, 28, cy, 11, {
                            { member.label or "?", "text", "disabled" },
                            { "  " .. (member.name or ""), "text", "disabled" },
                        })
                    end
                    local seen
                    if online then
                        seen = RCL["online"]
                    elseif info then
                        seen = string_format("%.0f min ago", (now-(info.lastSeen or 0))/60)
                    end
                    if seen then
                        local sFS = RC:CreateFontString(acctCard,"OVERLAY",nil,10)
                        sFS:SetPoint("TOPLEFT",acctCard,"TOPLEFT",360,cy)
                        sFS:SetText(seen)
                        Tint(sFS, "text", online and "success" or "gray")
                    end
                    cy = cy - 20
                end
            end
            cy = cy - 6
            local pingBtn = self.UI:CreateStyledButton(acctCard, RCL["Ping All"], 90, 24)
            pingBtn:SetPoint("TOPLEFT", acctCard, "TOPLEFT", 14, cy)
            pingBtn:SetScript("OnClick", function()
                if not MS:IsEnabled() then RC:Print(RCL["Mesh: Not enabled."]); return end
                local bhd = RC._mss and RC._mss.BuildHelloData
                MS:Broadcast("HELLO", (bhd and bhd()) or "")
                RC:Print(RCL["Mesh: Ping sent to all members."])
                C_Timer.After(2.5, function() RC:ShowSidebarMeshSync(frame) end)
            end)
            cy = cy - 14
            acctCard:SetContentHeight(math_abs(cy)); yPos = yPos - acctCard:GetHeight() - 10

            local myToonKey = UnitName("player") .. "-" .. GetRealmName()
            local sameAccToons = {}
            local saEnabledTbl = ReadycheckDB and ReadycheckDB.meshSyncEnabledPerChar
            -- Profile keys (ReadycheckDB.characters) use the RAW realm name;
            -- every mesh table uses the normalized one. Translate when
            -- looking mesh state up by a profile key.
            local function MeshKeyOf(charKey)
                local n, r = tostring(charKey):match("^([^%-]+)%-(.+)$")
                if n and r then return n .. "-" .. r:gsub("[%s'%-]", "") end
                return charKey
            end
            if ReadycheckDB and ReadycheckDB.characters then
                for charKey, profile in pairs(ReadycheckDB.characters) do
                    if charKey ~= myToonKey then
                        sameAccToons[#sameAccToons+1] = {
                            key     = charKey,
                            meshKey = MeshKeyOf(charKey),
                            enabled = saEnabledTbl and saEnabledTbl[MeshKeyOf(charKey)] == true,
                        }
                    end
                end
            end
            if #sameAccToons > 0 then
                local saCard = Card("Same account toons  (same-login sync)", yPos)
                local cy2 = -32
                DimFS(saCard, "Settings are exchanged via SavedVariables at login - no simultaneous connection needed.", 14, cy2); cy2 = cy2 - 14
                local state = ReadycheckDB and ReadycheckDB.meshSameAccountState
                for _, toon in ipairs(sameAccToons) do
                    local lastWrite   = nil
                    if state then
                        -- Per-character store: state[toonKey][categoryId],
                        -- keyed by the normalized form.
                        local cats = state[toon.meshKey or toon.key]
                        if type(cats) == "table" and not cats.fromChar then
                            for _, entry in pairs(cats) do
                                if type(entry) == "table"
                                        and (not lastWrite or (entry.savedAt or 0) > lastWrite) then
                                    lastWrite = entry.savedAt
                                end
                            end
                        end
                        -- Old flat entries that have not migrated yet.
                        for _, cat in ipairs(MS.SYNC_CATEGORIES or {}) do
                            local entry = state[cat.id]
                            if entry and (entry.fromChar == toon.key
                                    or entry.fromChar == toon.meshKey) then
                                if not lastWrite or (entry.savedAt or 0) > lastWrite then
                                    lastWrite = entry.savedAt
                                end
                            end
                        end
                    end
                    local hasData = lastWrite ~= nil
                    do local _dc = hasData and RC:GetColor("text", "blue") or RC:GetColor("raids", "disabled")
                        Dot(saCard, _dc.r, _dc.g, _dc.b, 14, cy2+2) end
                    local toonRuns = { { toon.key, "text", "normal" } }
                    if not toon.enabled then
                        toonRuns[2] = { " " .. RCL["(mesh off)"], "text", "disabled" }
                    end
                    RunFS(saCard, 28, cy2, 11, toonRuns)
                    if lastWrite then
                        local age = time() - lastWrite
                        local ageStr = age < 3600 and string_format("%.0f min ago", age/60)
                                    or string_format("%.1f hr ago", age/3600)
                        local aFS = RC:CreateFontString(saCard,"OVERLAY",nil,10)
                        aFS:SetPoint("TOPLEFT",saCard,"TOPLEFT",360,cy2)
                        aFS:SetText(RCL["synced "] .. ageStr)
                        Tint(aFS, "text", "gray")
                    end
                    cy2 = cy2 - 20
                end
                cy2 = cy2 - 4
                saCard:SetContentHeight(math_abs(cy2)); yPos = yPos - saCard:GetHeight() - 10
            end

            local logCard = Card("Recent activity", yPos)
            local lcy = -32
            local logEntries = MS.activityLog
            if not logEntries or #logEntries == 0 then
                DimFS(logCard, "No activity yet - syncs and connections will appear here.", 14, lcy); lcy = lcy - 18
            else
                for i = #logEntries, math.max(1, #logEntries - 9), -1 do
                    -- Log entries come from the mesh core and may carry their
                    -- own colour codes (chat-style); they are shown as-is.
                    DimFS(logCard, logEntries[i], 14, lcy)
                    lcy = lcy - 16
                end
            end
            lcy = lcy - 6
            local clearBtn = self.UI:CreateStyledButton(logCard, RCL["Clear Activity"], 110, 22)
            clearBtn:SetPoint("TOPLEFT",logCard,"TOPLEFT",14,lcy)
            clearBtn:SetScript("OnClick", function()
                if RC.MeshSync then RC.MeshSync.activityLog={} end
                RC:ShowSidebarMeshSync(frame)
            end)
            lcy = lcy - 10
            logCard:SetContentHeight(math_abs(lcy)); yPos = yPos - logCard:GetHeight() - 10

        elseif activeTab == "actions" then

            local members = MS:GetMembers()

            local bcastCard = Card("Broadcast", yPos)
            local cy = -32
            cy = (RC.UI:CreateHelpLine(bcastCard, 14, cy, "Push any category to your members - all categories are available here regardless of your Sync Rules. Use Target to send to one member or filter by class. Receivers only apply what their own Receive rules allow.", { gap = 6 }))

            local function ShortLbl(parent, text, ax, ay)
                local fs = RC:CreateFontString(parent,"OVERLAY",nil,11)
                fs:SetPoint("TOPLEFT",parent,"TOPLEFT",ax,ay)
                fs:SetText(text)
                Tint(fs, "text", "normal")
                return fs
            end

            ShortLbl(bcastCard, "Send to:", 14, cy)
            local classDisplay, myClass = UnitClass("player")
            local myCharName = UnitName("player") or ""
            classDisplay = classDisplay or ""; myClass = myClass or ""

            local selectedTarget = { type="", value="" }
            local selectedMember = nil

            local memberItems = { {label=RCL["All members"], value="all"} }
            for _, m in ipairs(members) do
                memberItems[#memberItems+1] = {label=(m.label or m.name), value=m.name, memberRef=m}
            end
            memberItems[#memberItems+1] = {label=RCL["My class only  ("] .. classDisplay .. ")", value="class"}
            memberItems[#memberItems+1] = {label=RCL["This character only  ("] .. myCharName .. ")", value="char"}

            local memberDrop = self.UI:CreateScrollableDropdown(bcastCard, 260, RCL["All members"], 8)
            memberDrop:SetEmptyText(RCL["No mesh members online"], RCL["Members appear once they log in with the mesh enabled."])
            memberDrop:SetPoint("TOPLEFT", bcastCard, "TOPLEFT", 75, cy)
            memberDrop:SetItems(memberItems, function(value, displayText)
                selectedMember = nil
                selectedTarget = {type="", value=""}
                if value == "all" then
                elseif value == "class" then
                    selectedTarget = {type="CLASS", value=myClass}
                elseif value == "char" then
                    selectedTarget = {type="CHAR", value=myCharName}
                else
                    for _, m in ipairs(members) do
                        if m.name == value then selectedMember = m; break end
                    end
                end
            end)
            cy = cy - 36

            local groups2, byGroup2 = {}, {}
            for _, cat in ipairs(cats) do
                if not MS.IsCategoryVisible or MS.IsCategoryVisible(cat) then
                    local g = cat.group or "Other"
                    if not byGroup2[g] then byGroup2[g]={}; groups2[#groups2+1]=g end
                    byGroup2[g][#byGroup2[g]+1] = cat
                end
            end

            local btnH = 24
            local function AddBtnRow(parent, leftLabel, rightLabel, cy)
                local rowFrame = CreateFrame("Frame", nil, parent)
                rowFrame:SetHeight(btnH)
                rowFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, cy)
                rowFrame:SetPoint("RIGHT",   parent, "RIGHT",  -14, 0)

                local lb = self.UI:CreateStyledButton(rowFrame, leftLabel,  1, btnH)
                lb:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", 0,  0)
                lb:SetPoint("RIGHT",   rowFrame, "TOP",    -3,  0)

                local rb
                if rightLabel then
                    rb = self.UI:CreateStyledButton(rowFrame, rightLabel, 1, btnH)
                    rb:SetPoint("TOPLEFT", rowFrame, "TOP",    3,  0)
                    rb:SetPoint("RIGHT",   rowFrame, "RIGHT",  0,  0)
                end
                return lb, rb
            end

            for _, groupName in ipairs(groups2) do
                local ghfs = RC:CreateFontString(bcastCard,"OVERLAY",nil,10)
                ghfs:SetPoint("TOPLEFT", bcastCard, "TOPLEFT", 14, cy)
                ghfs:SetText(groupName)
                Tint(ghfs, "ui", "accentGold"); cy = cy - 18

                local catList = byGroup2[groupName]
                local i = 1
                while i <= #catList do
                    local lCat = catList[i]
                    local rCat = catList[i + 1]
                    local lb, rb = AddBtnRow(bcastCard, lCat.label, rCat and rCat.label or nil, cy)

                    local lId = lCat.id
                    lb:SetScript("OnClick", function()
                        if not MS:IsEnabled() then RC:Print(RCL["Mesh: Not enabled."]); return end
                        MS:Push(lId, (selectedTarget.type~="") and selectedTarget or nil, selectedMember)
                    end)
                    if rb and rCat then
                        local rId = rCat.id
                        rb:SetScript("OnClick", function()
                            if not MS:IsEnabled() then RC:Print(RCL["Mesh: Not enabled."]); return end
                            MS:Push(rId, (selectedTarget.type~="") and selectedTarget or nil, selectedMember)
                        end)
                    end

                    cy = cy - (btnH + 4)
                    i = i + 2
                end
                cy = cy - 6
            end
            cy = cy - 4
            bcastCard:SetContentHeight(math_abs(cy)); yPos = yPos - bcastCard:GetHeight() - 10

            local reqCard = Card("Request", yPos)
            cy = -32
            cy = (RC.UI:CreateHelpLine(reqCard, 14, cy, "Ask a member to send you their copy of a specific data type.", { gap = 6 }))

            ShortLbl(reqCard, "From:", 14, cy); cy = cy - 18
            local selectedReqMember = nil
            local reqMemberItems = {{label=RCL["All members (broadcast)"], value="all"}}
            for _, m in ipairs(members) do
                reqMemberItems[#reqMemberItems+1] = {label=(m.label or m.name), value=m.name, memberRef=m}
            end
            local reqMemberDrop = self.UI:CreateScrollableDropdown(reqCard, 220, RCL["All members"], 7)
            reqMemberDrop:SetPoint("TOPLEFT",reqCard,"TOPLEFT",14,cy)
            reqMemberDrop:SetItems(reqMemberItems, function(value)
                selectedReqMember = nil
                if value ~= "all" then
                    for _, m in ipairs(members) do
                        if m.name == value then selectedReqMember = m; break end
                    end
                end
            end)
            cy = cy - 34

            ShortLbl(reqCard, "Data type:", 14, cy); cy = cy - 18
            local selectedReqCat = nil
            local catItems = {}
            for _, cat in ipairs(cats) do
                if not MS.IsCategoryVisible or MS.IsCategoryVisible(cat) then
                    catItems[#catItems+1] = {label=cat.label .. "  (" .. (cat.group or "") .. ")", value=cat.id}
                end
            end
            local catDrop = self.UI:CreateScrollableDropdown(reqCard, 300, RCL["Select data type..."], 8)
            catDrop:SetPoint("TOPLEFT",reqCard,"TOPLEFT",14,cy)
            catDrop:SetItems(catItems, function(value) selectedReqCat=value end)
            cy = cy - 34

            local reqBtn = self.UI:CreateStyledButton(reqCard, RCL["Request"], 100, 28)
            reqBtn:SetPoint("TOPLEFT",reqCard,"TOPLEFT",14,cy)
            reqBtn:SetScript("OnClick", function()
                if not MS:IsEnabled() then RC:Print(RCL["Mesh: Not enabled."]); return end
                if not selectedReqCat then RC:Print(RCL["Mesh: Choose a data type first."]); return end
                MS:Request(selectedReqMember, selectedReqCat)
                local target = selectedReqMember and (selectedReqMember.label or selectedReqMember.name) or "all members"
                RC:Print(RCL["Mesh: Requested from "] .. target .. ".")
            end)
            cy = cy - 28     -- (the button's own height: it sat on the card's bottom edge)
            reqCard:SetContentHeight(math_abs(cy)); yPos = yPos - reqCard:GetHeight() - 10

        elseif activeTab == "bar" then
            yPos = BuildMeshBarTab(self, parent, yPos)
        end

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
        self:RestoreScrollPosition(self.sidebarConfigFrame)
    end

end

InitializeSidebarMeshSync()

