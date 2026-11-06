------------------------------------------------------------------------
-- Readycheck - Remote Raid Config (Editor Session Lifecycle)
-- Owns entering/exiting "edit another toon's raid setup over mesh" and the
-- toon/raid picker panel. The contract other Raids_*.lua files rely on:
--   - RC.remoteEditMode = {member, raidKey} marks a session live; RC.
--     _remoteEditData holds a DEEP COPY of that toon's raid profile
--     structure (profiles/activeProfile/bosses/trash/route). UI code that
--     wants live "am I editing someone else" state checks remoteEditMode;
--     UI code that wants the data to read/write checks _remoteEditData.
--   - Runtime accessors (GetRaidProfileStructure/GetActiveRaidProfile in
--     RaidProfilesSystem.lua) are NEVER redirected by this file - they stay
--     pinned to RC.db (this character's own profile) so reminders/detection
--     never fire off someone else's config while you edit theirs.
--   - GetAllGearSets and SaveConfigurationToProfile are monkey-patched here
--     exactly once (guarded by _remoteEditGearSetWrapped/
--     _remoteEditSaveWrapped) so re-entering remote edit doesn't stack
--     wrappers. Both wrappers call through to the original first, then
--     branch on RC.remoteEditMode.
--   - SaveConfigurationToProfile's wrapper: origSave always runs first and
--     persists THIS character's own settings (harmless - it never touches
--     _remoteEditData). Only after that does it push the edited remote
--     data out: same-account toons get a direct ReadycheckDB.characters
--     write, everyone else goes through MeshSync:PushOrQueueRaidConfig.
--   - Exiting (ExitRemoteEditMode) does one final flush the same way, then
--     clears remoteEditMode/_remoteEditData so runtime and editor accessors
--     converge back on the local profile.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)
local GetSpellInfo = GetSpellInfo or (RCC and RCC.Compat and RCC.Compat.GetSpellInfo)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local table_insert, table_remove, table_sort = table.insert, table.remove, table.sort
local string_format, string_lower = string.format, string.lower
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local RC = _G.Readycheck
if not (RC and RC.UI) then return end
RC._sbr = RC._sbr or {}
local _sbr = RC._sbr
    -- member/raidKey identify whose config and which raid; data is the raid
    -- profile structure to edit (already fetched, or a same-account local
    -- copy); gearSetNames lists the remote toon's known gear set names
    -- since their GearManager.sets table isn't visible locally - GetAllGearSets
    -- below is patched to substitute this list while a session is live.
    function RC:EnterRemoteEditMode(member, raidKey, data, gearSetNames)
        -- Switching target mid-session (different toon or different raid on
        -- the same toon) flushes the previous session's edits before
        -- overwriting _remoteEditData, otherwise they'd be lost silently.
        local prev = RC.remoteEditMode
        if prev and RC._remoteEditData
                and not (prev.raidKey == raidKey
                         and prev.member and member
                         and prev.member.name == member.name) then
            RC:ExitRemoteEditMode()
        end
        RC._remoteEditData = RC.DeepCopy(data)
        RC._remoteEditGearSetNames = gearSetNames or nil

        if RC.rrcState then
            RC.rrcState.fetchedGearSetNames = gearSetNames or nil
        end
        if gearSetNames and ReadycheckDB and ReadycheckDB.remoteRaidConfigs then
            local rawName = (member.name or ""):lower():gsub("%-.*$", "")
            for ck, byRaid in pairs(ReadycheckDB.remoteRaidConfigs) do
                if ck:lower():gsub("%-.*$", "") == rawName then
                    if byRaid[raidKey] then
                        byRaid[raidKey].gearSetNames = gearSetNames
                    end
                    break
                end
            end
        end

        RC.remoteEditMode = {
            member  = member,
            raidKey = raidKey,
        }
        RC.remoteStagedRaidConfig = nil

        if ReadycheckDB then
            local ck = member.name or ""
            if ck ~= "" and not ck:find("-", 1, true) then
                local realm = (GetNormalizedRealmName and GetNormalizedRealmName())
                    or (GetRealmName() or ""):gsub("%s+", "")
                if realm ~= "" then ck = ck .. "-" .. realm end
            end
            ReadycheckDB.remoteEditSession = {
                memberName  = member.name  or "",
                memberLabel = member.label or member.name or "",
                raidKey     = raidKey,
                charKey     = ck,
            }
        end

        -- Patched once and left in place for the addon's lifetime; the "if
        -- rem" branch inside makes it a no-op transparently whenever no
        -- remote session is open, so leaving the wrapper installed after
        -- ExitRemoteEditMode is safe.
        if not RC._remoteEditGearSetWrapped then
            local origGetAllGearSets = RC.GetAllGearSets
            RC.GetAllGearSets = function(self)
                local rem = RC.remoteEditMode
                if rem then
                    local sets, seen = {}, {}
                    if RC._remoteEditGearSetNames then
                        for _, sn in pairs(RC._remoteEditGearSetNames) do
                            if type(sn) == "string" and not seen[sn] then
                                table.insert(sets, { name = sn, source = "Remote" })
                                seen[sn] = true
                            end
                        end
                    end
                    if RC._remoteEditData and RC._remoteEditData.profiles then
                        for _, pd in pairs(RC._remoteEditData.profiles) do
                            if pd.bosses then
                                for _, bd in pairs(pd.bosses) do
                                    local gs = bd.abilities and bd.abilities.gearswap
                                    if gs then
                                        for _, field in ipairs({"gearSet", "postCombatSet"}) do
                                            local sn = gs[field]
                                            if type(sn) == "string" and sn ~= "" then
                                                local clean = sn:gsub("^ItemRack:", "")
                                                if not seen[clean] then
                                                    table.insert(sets, { name = clean, source = "Remote" })
                                                    seen[clean] = true
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                    if #sets > 0 then
                        table.sort(sets, function(a, b) return a.name < b.name end)
                        return sets
                    end
                end
                return origGetAllGearSets(self)
            end
            RC._origGetAllGearSets      = origGetAllGearSets
            RC._remoteEditGearSetWrapped = true
        end

        -- origSave still runs unconditionally first - it persists this
        -- character's own ReadycheckDB.characters entry and never touches
        -- _remoteEditData, so it's a harmless local save even mid-session.
        -- The push below is what actually propagates the remote edits.
        if not RC._remoteEditSaveWrapped then
            local origSave = RC.SaveConfigurationToProfile
            RC.SaveConfigurationToProfile = function(self2, ...)
                origSave(self2, ...)
                local rem = RC.remoteEditMode
                if rem and RC._remoteEditData then
                    if rem.member and rem.member.isSameAccount then
                        local ck = rem.member.charKey
                        if ck and ReadycheckDB and ReadycheckDB.characters
                                and ReadycheckDB.characters[ck] then
                            ReadycheckDB.characters[ck].raidProfiles =
                                ReadycheckDB.characters[ck].raidProfiles or {}
                            ReadycheckDB.characters[ck].raidProfiles[rem.raidKey] =
                                RC.DeepCopy(RC._remoteEditData)
                        end
                    else
                        local MS2 = RC.MeshSync
                        if MS2 and MS2.PushOrQueueRaidConfig then
                            MS2:PushOrQueueRaidConfig(rem.member, rem.raidKey, RC._remoteEditData)
                        end
                    end
                end
            end
            RC._remoteEditSaveWrapped = true
            RC._origSaveConfig        = origSave
        end

        local cf = RC.sidebarConfigFrame and RC.sidebarConfigFrame.compatFrame
        if cf and RC.sidebarConfigFrame:IsShown() then
            cf.configState = cf.configState or {}
            cf.configState.selectedRaid          = raidKey
            cf.configState.selectedEncounter     = nil
            cf.configState.selectedEncounterType = nil
            cf.configState.selectedAbility       = nil
            cf.configState.selectedTrashSection  = nil
            RC.SidebarState.currentPanel = "remote_raid_cfg"
            RC:OpenRaidBossPage(cf, raidKey)
        elseif RC.sidebarConfigFrame and RC.sidebarConfigFrame:IsShown() then
            RC.SidebarState.currentPanel = "remote_raid_cfg"
            C_Timer.After(0.05, function()
                local cf2 = RC.sidebarConfigFrame and RC.sidebarConfigFrame.compatFrame
                if cf2 then RC:ShowSidebarRemoteRaidConfig(cf2) end
            end)
        end

        RC:DebugPrint("EnterRemoteEditMode: " .. raidKey .. " for " ..
            (member.label or member.name or "?"), "meshsync")
    end

    -- Final flush before tearing down the session - same same-account vs.
    -- mesh split as the SaveConfigurationToProfile wrapper above, since this
    -- runs after remoteEditMode is cleared and that wrapper's branch won't
    -- fire again.
    function RC:ExitRemoteEditMode()
        local rem = RC.remoteEditMode
        if not rem then return end

        if RC._remoteEditData then
            if rem.member and rem.member.isSameAccount then
                local ck = rem.member.charKey
                if ck and ReadycheckDB and ReadycheckDB.characters
                        and ReadycheckDB.characters[ck] then
                    ReadycheckDB.characters[ck].raidProfiles =
                        ReadycheckDB.characters[ck].raidProfiles or {}
                    ReadycheckDB.characters[ck].raidProfiles[rem.raidKey] =
                        RC.DeepCopy(RC._remoteEditData)
                end
            else
                local MS = RC.MeshSync
                if MS and MS.FlushRemoteEditNow then
                    MS:FlushRemoteEditNow(rem.member, rem.raidKey, RC._remoteEditData)
                end
            end
        end

        RC._remoteEditData          = nil
        RC._remoteEditGearSetNames  = nil
        RC.remoteEditMode           = nil
        RC.remoteStagedRaidConfig   = nil
        if ReadycheckDB then
            ReadycheckDB.remoteEditSession     = nil
            ReadycheckDB.remoteEditLastSession = nil
        end

        local cf = RC.sidebarConfigFrame and RC.sidebarConfigFrame.compatFrame
        if cf then RC:ShowSidebarRemoteRaidConfig(cf) end
        RC.SidebarState.currentPanel = "remote_raid_cfg"
    end

    function RC:ShowSidebarRemoteRaidConfig(frame)
        self:ClearSidebarContent(self.sidebarConfigFrame)
        local parent = frame.scrollChild
        local yPos   = -20

        local _, newY = self:CreateSettingsPageHeader(parent, yPos,
            RCL["Remote Raid Config"],
            RCL["Edit another toon's raid settings - changes sync automatically"],
            "Interface\\Icons\\INV_Letter_16")
        yPos = newY

        local function DimFS(p, txt, x, y2)
            local fs = RC:CreateFontString(p, "OVERLAY", nil, 10)
            fs:SetPoint("TOPLEFT", p, "TOPLEFT", x, y2)
            fs:SetPoint("RIGHT", p, "RIGHT", -15, 0)
            fs:SetJustifyH("LEFT")
            local c = RC:GetColor("text", "gray") or {r=0.5,g=0.5,b=0.5}
            fs:SetTextColor(c.r, c.g, c.b)
            fs:SetText(txt); return fs
        end
        local function NormFS(p, txt, x, y2)
            local fs = RC:CreateFontString(p, "OVERLAY", nil, 11)
            fs:SetPoint("TOPLEFT", p, "TOPLEFT", x, y2)
            local c = RC:GetColor("text", "normal") or {r=0.8,g=0.8,b=0.8}
            fs:SetTextColor(c.r, c.g, c.b)
            fs:SetText(txt); return fs
        end
        local function MemberDisplay(m)
            local cn = m.name and m.name:match("^([^%-]+)") or m.name or ""
            local lb = m.label or ""
            return (lb ~= "" and lb ~= cn) and (lb .. "  (" .. cn .. ")") or cn
        end

        local MS = RC.MeshSync

        if not (MS and MS:IsEnabled()) then
            local c = self:CreateSettingsCard(parent, yPos, RCL["Mesh network required"])
            local cy = -30
            DimFS(c, "Enable Mesh Network to use Remote Raid Config.", 15, cy)
            cy = cy - 26
            c:SetContentHeight(math.abs(cy))
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
            return
        end

        if RC.remoteEditMode then
            local rem      = RC.remoteEditMode
            local charName = rem.member.name and rem.member.name:match("^([^%-]+)") or "?"
            local lbl      = rem.member.label or ""
            local who      = (lbl ~= "" and lbl ~= charName)
                             and (lbl .. "  (" .. charName .. ")") or charName

            local sCard = self:CreateSettingsCard(parent, yPos, RCL["Remote edit active"])
            local scy = -30
            DimFS(sCard, "Editing |cFFFFD700" .. rem.raidKey .. "|r for |cFFFFD700"
                .. who .. "|r - changes are syncing automatically.", 15, scy)
            scy = scy - 28

            local resumeBtn = self.UI:CreateStyledButton(sCard, RCL["Resume Editing"], 140, 26)
            resumeBtn:SetPoint("TOPLEFT", sCard, "TOPLEFT", 15, scy)
            resumeBtn:SetScript("OnClick", function()
                local cf = RC.sidebarConfigFrame and RC.sidebarConfigFrame.compatFrame
                if not cf then return end
                cf.configState = cf.configState or {}
                cf.configState.selectedRaid          = rem.raidKey
                cf.configState.selectedEncounter     = nil
                cf.configState.selectedEncounterType = nil
                cf.configState.selectedAbility       = nil
                RC:OpenRaidBossPage(cf, rem.raidKey)
                RC.SidebarState.currentPanel = "remote_raid_cfg"
            end)

            local exitBtn = self.UI:CreateStyledButton(sCard, RCL["Back"], 60, 26)
            exitBtn:SetPoint("LEFT", resumeBtn, "RIGHT", 8, 0)
            exitBtn:SetScript("OnClick", function() RC:ExitRemoteEditMode() end)

            scy = scy - 14
            sCard:SetContentHeight(math.abs(scy))
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
            return
        end

        local staged = RC.remoteStagedRaidConfig
        if staged and staged.pending then
            local wCard = self:CreateSettingsCard(parent, yPos, RCL["Fetching config"])
            local wcy = -30
            local wm    = staged.member
            local wcn   = wm and wm.name and wm.name:match("^([^%-]+)") or "?"
            local wlbl  = wm and wm.label or ""
            local who2  = (wlbl ~= "" and wlbl ~= wcn) and (wlbl .. " (" .. wcn .. ")") or wcn
            DimFS(wCard,
                "Waiting for " .. who2 ..
                " - they must be online with Mesh enabled.",
                15, wcy)
            wcy = wcy - 26

            local cancelBtn = self.UI:CreateStyledButton(wCard, RCL["Cancel"], 80, 24)
            cancelBtn:SetPoint("TOPLEFT", wCard, "TOPLEFT", 15, wcy)
            cancelBtn:SetScript("OnClick", function()
                RC.remoteStagedRaidConfig = nil
                local cf2 = RC.sidebarConfigFrame and RC.sidebarConfigFrame.compatFrame
                if cf2 then RC:ShowSidebarRemoteRaidConfig(cf2) end
            end)
            wcy = wcy - 10

            wCard:SetContentHeight(math.abs(wcy))
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
            return
        end

        RC.rrcState = RC.rrcState or {}
        local st = RC.rrcState

        if not st.selectedMember
                and ReadycheckDB
                and ReadycheckDB.remoteEditSession then
            local ls = ReadycheckDB.remoteEditSession
            if ls.memberName and ls.memberName ~= "" and ls.raidKey then
                st.selectedMember = { name = ls.memberName, label = ls.memberLabel or "" }
                st.memberLabel    = ls.memberLabel or ls.memberName
                st.raidKey        = ls.raidKey
            end
        end

        local tCard = self:CreateSettingsCard(parent, yPos, RCL["Select toon"])
        local tcy = -30
        DimFS(tCard,
            "Fetch a toon's raid config and edit it directly using the normal raid settings. " ..
            "Changes sync automatically while they're online, or queue for their next login.",
            15, tcy)
        tcy = tcy - 28

        NormFS(tCard, "Toon:", 15, tcy)
        local members     = MS.GetMembers and MS:GetMembers() or {}
        local memberItems = {}
        local sameAcctByValue = {}
        for _, m in ipairs(members) do
            memberItems[#memberItems+1] = { label = MemberDisplay(m), value = m.name }
        end
        local myCharKey = RC.GetCharacterKey and RC:GetCharacterKey() or ""
        if ReadycheckDB and ReadycheckDB.characters then
            for ck, charData in pairs(ReadycheckDB.characters) do
                if ck ~= myCharKey and charData and charData.raidProfiles then
                    local charName = ck:match("^(.-)%-") or ck
                    local val = "sameacct:" .. ck
                    memberItems[#memberItems+1] = {
                        label = charName .. "  [same account]",
                        value = val,
                    }
                    sameAcctByValue[val] = ck
                end
            end
        end
        local memberDrop = self.UI:CreateScrollableDropdown(tCard, 240,
            st.memberLabel or RCL["Select toon..."], 8)
        memberDrop:SetEmptyText(RCL["No toons to edit yet"], RCL["Mesh members and your other characters with raid settings show up here."])
        memberDrop:SetPoint("TOPLEFT", tCard, "TOPLEFT", 56, tcy)
        memberDrop:SetItems(memberItems, function(value, displayText)
            st.selectedMember = nil
            st.memberLabel    = displayText
            local saCK = sameAcctByValue[value]
            if saCK then
                local charName = saCK:match("^(.-)%-") or saCK
                st.selectedMember = { name = saCK, label = charName, isSameAccount = true, charKey = saCK }
            else
                for _, m in ipairs(members) do
                    if m.name == value then st.selectedMember = m; break end
                end
            end
            local cf2 = RC.sidebarConfigFrame and RC.sidebarConfigFrame.compatFrame
            if cf2 then RC:ShowSidebarRemoteRaidConfig(cf2) end
        end)
        tcy = tcy - 32

        tcy = tcy - 4

        local memberIsOnline = false
        if st.selectedMember then
            if MS.IsCharOnline then
                memberIsOnline = MS:IsCharOnline(st.selectedMember.name)
            else
                local targetName = st.selectedMember.name and
                    st.selectedMember.name:match("^([^%-]+)") or ""
                local known = MS.GetKnownAccounts and MS:GetKnownAccounts() or {}
                for _, acct in pairs(known) do
                    local ac = acct.charName and acct.charName:match("^([^%-]+)") or ""
                    if acct.online and ac ~= "" and ac == targetName then
                        memberIsOnline = true; break
                    end
                end
            end
        end

        local function CachedFor(raidKey)
            if not (st.selectedMember and raidKey) then return nil end
            local ck = st.selectedMember.name
            if ck and not ck:find("-", 1, true) then
                local realm = (GetNormalizedRealmName and GetNormalizedRealmName())
                    or (GetRealmName() or ""):gsub("%s+", "")
                if realm ~= "" then ck = ck .. "-" .. realm end
            end
            return ReadycheckDB
                and ReadycheckDB.remoteRaidConfigs
                and ReadycheckDB.remoteRaidConfigs[ck]
                and ReadycheckDB.remoteRaidConfigs[ck][raidKey]
        end

        local function doFetch(raidKey, cached, useCacheIfOffline)
            local capM = st.selectedMember
            local capR = raidKey
            if not capM then
                RC:Print(RCL["Mesh: Remote Raid Config: select a toon first."]); return
            end
            st.raidKey = capR

            -- Same-account toons skip mesh entirely: their raid profiles are
            -- already in this account's SavedVariables, so this reads
            -- straight out of ReadycheckDB.characters instead of fetching.
            if capM.isSameAccount then
                local ck       = capM.charKey
                local charData = ReadycheckDB and ReadycheckDB.characters and ReadycheckDB.characters[ck]
                local raidProf = charData and charData.raidProfiles and charData.raidProfiles[capR]
                if not raidProf then
                    RC:Print(string_format(
                        "Mesh: |cFFFFD700%s|r has no config for |cFFFFD700%s|r.",
                        capM.label or ck, capR))
                    return
                end
                local gsn = {}
                if charData.gearSets then
                    for name in pairs(charData.gearSets) do gsn[#gsn+1] = name end
                end
                RC.remoteStagedRaidConfig = nil
                RC:EnterRemoteEditMode(capM, capR, RC.DeepCopy(raidProf), gsn)
                return
            end

            if not memberIsOnline then
                if useCacheIfOffline and cached and cached.data then
                    RC.remoteStagedRaidConfig = nil
                    RC:EnterRemoteEditMode(capM, capR, cached.data,
                        cached.gearSetNames or st.fetchedGearSetNames)
                else
                    RC:Print(string_format(
                        "Mesh: |cFFFFD700%s|r is offline - " ..
                        (cached and "use Resume to edit the local copy."
                         or "fetch not available until they log in."),
                        capM.label or capM.name))
                end
                return
            end
            RC.remoteStagedRaidConfig = { member = capM, raidKey = capR, pending = true }
            MS:FetchRaidConfigForEdit(capM, capR)
            self:ShowSidebarRemoteRaidConfig(frame)

            -- fetchToken guards against this timeout firing after a newer
            -- fetch has already replaced remoteStagedRaidConfig (e.g. user
            -- cancelled and re-fetched within the 90s window).
            local fetchToken = GetTime()
            RC.remoteStagedRaidConfig._fetchToken = fetchToken
            C_Timer.After(90, function()
                local st2 = RC.remoteStagedRaidConfig
                if st2 and st2.pending and st2._fetchToken == fetchToken then
                    RC.remoteStagedRaidConfig = nil
                    RC:Print(string_format(
                        "Mesh: No response from |cFFFFD700%s|r - " ..
                        "they may have gone offline or Mesh may not be connected. " ..
                        "Try again or use Resume if a local copy is available.",
                        capM.label or capM.name or "?"))
                    local cf2 = RC.sidebarConfigFrame and RC.sidebarConfigFrame.compatFrame
                    if cf2 and RC.sidebarConfigFrame:IsShown()
                            and RC.SidebarState
                            and RC.SidebarState.currentPanel == "remote_raid_cfg" then
                        RC:ShowSidebarRemoteRaidConfig(cf2)
                    end
                end
            end)
        end

        if not st.selectedMember then
            DimFS(tCard, "Pick a toon above, then click a raid to edit it.", 15, tcy)
            tcy = tcy - 22
        else
            local raidOrder = {
                "Naxxramas", "Temple of Ahn'Qiraj", "Blackwing Lair",
                "Molten Core", "Onyxia's Lair", "Zul'Gurub", "Ruins of Ahn'Qiraj",
            }
            for _, raidKey in ipairs(raidOrder) do
                if self.raidData and self.raidData[raidKey] then
                    local cached  = CachedFor(raidKey)
                    -- Older cached fetches may predate gear-swap data being
                    -- included in the payload; isStale forces a fresh fetch
                    -- instead of silently editing an incomplete local copy.
                    local isStale = cached and not cached.gearIncluded

                    local rBtn = self.UI:CreateStyledButton(tCard, raidKey, 170, 24)
                    rBtn:SetPoint("TOPLEFT", tCard, "TOPLEFT", 15, tcy)
                    rBtn:SetScript("OnClick", function()
                        doFetch(raidKey, (not isStale) and cached or nil, true)
                    end)

                    local statusTxt
                    if cached and cached.savedAt then
                        local age    = time() - cached.savedAt
                        local ageStr = age < 3600
                            and string_format("%.0f min ago", age / 60)
                            or  string_format("%.1f hr ago",  age / 3600)
                        statusTxt = "local copy " .. ageStr
                            .. (isStale and "  |cFFFF6666(no gear - fetch fresh)|r" or "")
                    elseif memberIsOnline or (st.selectedMember and st.selectedMember.isSameAccount) then
                        statusTxt = "click to fetch & edit"
                    else
                        statusTxt = "offline - no local copy"
                    end
                    local sFS = RC:CreateFontString(tCard, "OVERLAY", nil, 10)
                    sFS:SetPoint("LEFT", rBtn, "RIGHT", 10, 0)
                    local gc = RC:GetColor("text", "gray") or {r=0.5,g=0.5,b=0.5}
                    sFS:SetTextColor(gc.r, gc.g, gc.b)
                    sFS:SetText(statusTxt)

                    if cached and not isStale and memberIsOnline then
                        local freshBtn = self.UI:CreateStyledButton(tCard, RCL["Fetch Fresh"], 90, 20)
                        freshBtn:SetPoint("TOPRIGHT", tCard, "TOPRIGHT", -15, tcy - 2)
                        freshBtn:SetScript("OnClick", function()
                            doFetch(raidKey, nil, false)
                        end)
                    end

                    tcy = tcy - 30
                end
            end
            DimFS(tCard,
                "Clicking a raid opens the normal raid editor for that toon - bosses, trash, "
                .. "gear and the Route, exactly like editing your own. A raid with a local copy "
                .. "resumes from it when they're offline.",
                15, tcy)
            tcy = tcy - 34
        end
        tcy = tcy - 6
        tCard:SetContentHeight(math.abs(tcy))

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
    end

    RC:DebugPrint("ConfigUI_Raids panels loaded", "system")
