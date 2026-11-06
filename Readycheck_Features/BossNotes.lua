------------------------------------------------------------------------
-- Readycheck - Boss Notes
-- Per-boss and per-trash-pack text shown on a movable frame when the
-- matching mob is targeted, an encounter starts, or a kill count is met.
-- Every note key is profile-scoped with "|": db.notes uses
-- "<mob>|<raid long name>|<profile>", db.trashNotesByRaid and
-- db.trashNotesList use "<raidKey>|<profile>", db.trashNotesByPack is
-- [raidKey]["<packKey>|<profile>"]. Unscoped keys are legacy and get
-- migrated once per profile by InitializeBossNotesDB.
-- Mesh sync is MERGE-ONLY: an inbound note is written only where the
-- local slot is missing or empty, so syncing never overwrites and never
-- deletes anything the user has locally.
------------------------------------------------------------------------

local function InitializeBossNotes()
    local RC = _G.Readycheck
    if not RC then C_Timer.After(0.1, InitializeBossNotes); return end
    if not RC.db then C_Timer.After(0.2, InitializeBossNotes); return end
    if not RC.UI then C_Timer.After(0.2, InitializeBossNotes); return end
    -- keyed to the Classic Era raids (Core_Flavor)
    if RC.FeatureOn and not RC:FeatureOn("boss_notes") then return end

    -- the note box draws through Cons_Notes' StyleBossNotesBox: the page
    -- offers fonts, colours and animations once this is set
    RC.BOSS_NOTES_STYLE_LIVE = RC.StyleBossNotesBox ~= nil
    -- entrance / exit from the page's settings (nil = shown and hidden at once)
    local NO_ANIM = { style = "none" }
    local function ShowNote(frame, db)
        if not frame:IsShown() or (frame._rcMotion and frame._rcMotion.how == "out") then
            RC.Motion.Show(frame, RC.Motion.Normalize(db and db.showAnim, RC.BOSS_NOTE_ANIM_DEFAULTS or NO_ANIM))
        end
    end
    local function HideNote(frame, db)
        if frame:IsShown() then
            RC.Motion.Hide(frame, RC.Motion.Normalize(db and db.hideAnim, RC.BOSS_NOTE_ANIM_DEFAULTS or NO_ANIM))
        end
    end

    RC.bossNotes = {
        frame = nil,
        lingerTimer = nil,
        lastNote = nil,
        npCurrentRaidKey = nil,
    }

    -- Matched as a lowercase substring of GetRealZoneText, so both spellings
    -- the client has shipped for AQ40 resolve to the same key.
    local RAID_KEY_BY_NAME = {
        ["molten core"]         = "mc",
        ["blackwing lair"]      = "bwl",
        ["temple of ahn'qiraj"] = "aq40",
        ["ahn'qiraj temple"]    = "aq40",
        ["naxxramas"]           = "naxx",
        ["zul'gurub"]           = "zg",
        ["onyxia's lair"]       = "onyxia",
    }

    -- Short key <-> long name: note keys carry the LONG name because that is
    -- what the raid profile system is keyed by, while trash keys carry the
    -- short one. Both spellings of the same raid must never both be stored.
    local RAID_LONG_NAME_BY_KEY = {
        mc     = "Molten Core",
        bwl    = "Blackwing Lair",
        aq40   = "Temple of Ahn'Qiraj",
        naxx   = "Naxxramas",
        zg     = "Zul'Gurub",
        onyxia = "Onyxia's Lair",
        aq20   = "Ruins of Ahn'Qiraj",
    }

    -- Profile names known for a raid (long name); "Default" when none are.
    -- Shared by the one-shot WRN1 profile-isolation migration and by
    -- ImportBossNotes, which re-scopes unscoped WRN1 keys the same way.
    local function ProfilesFor(raidLong)
        local names = {}
        local structure = RC.GetRaidProfileStructure
            and RC:GetRaidProfileStructure(raidLong)
        if structure and type(structure.profiles) == "table" then
            for pName in pairs(structure.profiles) do
                names[#names + 1] = pName
            end
        end
        if #names == 0 then names[1] = "Default" end
        return names
    end

    -- Lowercased-key index over db.notes. Keys are stored in their original
    -- case but looked up lowercased, so LookupNote reads this index instead
    -- of walking the whole map on every target change. Built lazily; every
    -- note add/edit/delete in the addon (note editor, import, mesh merge,
    -- migrations) is followed by RC:SaveConfigurationToProfile, so a hook
    -- there is the single invalidation chokepoint. A profile switch swaps
    -- RC.db wholesale, which the source-table identity check catches.
    local noteIndex, noteIndexSource

    function RC:InvalidateBossNoteIndex()
        noteIndex = nil
    end

    local function GetBossNoteIndex(notes)
        if noteIndex and noteIndexSource == notes then return noteIndex end
        noteIndexSource = notes
        noteIndex = {}
        for k, v in pairs(notes) do
            if type(k) == "string" and v and v ~= "" then
                noteIndex[k:lower()] = v
            end
        end
        return noteIndex
    end

    if not RC._bossNoteIndexHooked
       and type(RC.SaveConfigurationToProfile) == "function" then
        RC._bossNoteIndexHooked = true
        hooksecurefunc(RC, "SaveConfigurationToProfile", function()
            noteIndex = nil
        end)
    end

    local function DetectCurrentRaidKey()
        local inInstance, instanceType = IsInInstance()
        if not inInstance or instanceType ~= "raid" then return nil end
        local zone = GetRealZoneText() or GetZoneText() or ""
        local lower = zone:lower()
        for pattern, key in pairs(RAID_KEY_BY_NAME) do
            if lower:find(pattern, 1, true) then return key end
        end
        return nil
    end

    function RC:InitializeBossNotesDB()
        if not self.db.bossNotes then self.db.bossNotes = {} end
        local db = self.db.bossNotes
        local defaults = {
            enabled         = true,
            locked          = true,
            xOffset         = 0,
            yOffset         = 150,
            scale           = 1.0,
            opacity         = 0.85,
            fontSize        = 14,
            showBackground  = true,
            showForTrash    = true,
            lingerDuration  = 0,
            notes           = {},

            trashNotesByRaid = {},

            trashNotesByPack = {},

            ttsEnabled      = false,
            ttsTrigger      = "encounter_start",
        }
        for k, v in pairs(defaults) do
            if db[k] == nil then db[k] = v end
        end
        if type(db.notes)             ~= "table" then db.notes = {} end
        if type(db.trashNotesByRaid)  ~= "table" then db.trashNotesByRaid = {} end
        if type(db.trashNotesByPack)  ~= "table" then db.trashNotesByPack = {} end
        if type(db.trashNoteKills) ~= "table" then db.trashNoteKills = {} end
        if type(db.trashNoteDur)   ~= "table" then db.trashNoteDur   = {} end
        if type(db.trashNotesList)    ~= "table" then db.trashNotesList    = {} end
        if type(db.trashNotesListMig) ~= "table" then db.trashNotesListMig = {} end
        if type(db.bossNoteAdded)     ~= "table" then db.bossNoteAdded     = {} end

        if db.trashNote and db.trashNote ~= "" then
            local allRaids = {"mc","bwl","aq40","naxx","zg","onyxia","aq20"}
            for _, k in ipairs(allRaids) do
                local scoped = k .. "|Default"
                if not db.trashNotesByRaid[scoped] or db.trashNotesByRaid[scoped] == "" then
                    db.trashNotesByRaid[scoped] = db.trashNote
                end
            end
            self:DebugPrint("Migrated legacy db.trashNote to per-raid Default-profile slots", "profile")
            db.trashNote = nil
        end

        -- One-shot per profile: flat unscoped keys are copied out to every
        -- raid/profile combination that exists, then removed. Copies only
        -- land in slots that are empty, so nothing already written is lost.
        if not db.profileIsolationMigrated then
            local raidLongs = {
                "Molten Core", "Blackwing Lair", "Temple of Ahn'Qiraj",
                "Naxxramas", "Zul'Gurub", "Onyxia's Lair", "Ruins of Ahn'Qiraj",
            }
            local raidShorts = {"mc","bwl","aq40","naxx","zg","onyxia","aq20"}

            local migratedNotes = 0
            for k, v in pairs(db.notes) do
                if type(k) == "string" and not k:find("|", 1, true)
                   and v and v ~= "" then
                    for _, raidLong in ipairs(raidLongs) do
                        for _, prof in ipairs(ProfilesFor(raidLong)) do
                            local scoped = k .. "|" .. raidLong .. "|" .. prof
                            if not db.notes[scoped] or db.notes[scoped] == "" then
                                db.notes[scoped] = v
                            end
                        end
                    end
                    db.notes[k] = nil
                    migratedNotes = migratedNotes + 1
                end
            end

            local migratedRaid = 0
            for k, v in pairs(db.trashNotesByRaid) do
                if type(k) == "string" and not k:find("|", 1, true)
                   and v and v ~= "" then
                    local rl = RAID_LONG_NAME_BY_KEY[k]
                    for _, prof in ipairs(ProfilesFor(rl or "")) do
                        local scoped = k .. "|" .. prof
                        if not db.trashNotesByRaid[scoped] or db.trashNotesByRaid[scoped] == "" then
                            db.trashNotesByRaid[scoped] = v
                        end
                    end
                    db.trashNotesByRaid[k] = nil
                    migratedRaid = migratedRaid + 1
                end
            end

            local migratedPack = 0
            for raidKey, packs in pairs(db.trashNotesByPack) do
                if type(packs) == "table" then
                    for pk, v in pairs(packs) do
                        if type(pk) == "string" and not pk:find("|", 1, true)
                           and v and v ~= "" then
                            local rl = RAID_LONG_NAME_BY_KEY[raidKey]
                            for _, prof in ipairs(ProfilesFor(rl or "")) do
                                local scoped = pk .. "|" .. prof
                                if not packs[scoped] or packs[scoped] == "" then
                                    packs[scoped] = v
                                end
                            end
                            packs[pk] = nil
                            migratedPack = migratedPack + 1
                        end
                    end
                end
            end

            db.profileIsolationMigrated = true
            self:DebugPrint(string.format(
                RCL["BossNotes profile-isolation migration: %d mob, %d raid, %d pack flat keys -> all profiles"],
                migratedNotes, migratedRaid, migratedPack), "profile")
        end

        if self.RepairBossNoteProfiles then self:RepairBossNoteProfiles() end
    end

    -- Repairs profile scoping in two passes. First: drop non-Default copies
    -- byte-identical to their Default sibling, so an old blanket copy stops
    -- pinning every profile to the same text. Second: re-seed empty Default
    -- slots and adopt notes stranded under profile names that no longer
    -- exist. Both passes only fill empty slots or remove exact duplicates -
    -- an edited note is never overwritten and nothing unique is deleted.
    function RC:RepairBossNoteProfiles()
        local db = self.db and self.db.bossNotes
        if not db then return end

        if db.profileIsolationRepaired2 and not db.bossNotesSprayUndone then
            db.bossNotesSprayUndone = true
            local undone = 0
            for k, v in pairs(db.notes) do
                local mob, rl, prof = k:match("^(.-)|(.-)|(.-)$")
                if mob and prof and prof ~= "Default" then
                    if db.notes[mob .. "|" .. rl .. "|Default"] == v then
                        db.notes[k] = nil
                        undone = undone + 1
                    end
                end
            end
            for k, v in pairs(db.trashNotesByRaid) do
                local base, prof = k:match("^(.-)|(.-)$")
                if base and prof and prof ~= "Default" then
                    if db.trashNotesByRaid[base .. "|Default"] == v then
                        db.trashNotesByRaid[k] = nil
                        undone = undone + 1
                    end
                end
            end
            for rk2, packs in pairs(db.trashNotesByPack) do
                if type(packs) == "table" then
                    for k, v in pairs(packs) do
                        local base, prof = k:match("^(.-)|(.-)$")
                        if base and prof and prof ~= "Default" then
                            if packs[base .. "|Default"] == v then
                                packs[k] = nil
                                undone = undone + 1
                            end
                        end
                    end
                end
            end
            local function SameList(a, b)
                if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
                for i = 1, #a do
                    local x, y2 = a[i], b[i]
                    if type(x) ~= "table" or type(y2) ~= "table" then return false end
                    if x.text ~= y2.text or (x.kills or 1) ~= (y2.kills or 1)
                       or (x.dur or 8) ~= (y2.dur or 8)
                       or (x.trigger or "kills") ~= (y2.trigger or "kills") then
                        return false
                    end
                    local xm, ym = x.mobs or {}, y2.mobs or {}
                    if #xm ~= #ym then return false end
                    for mi = 1, #xm do
                        if xm[mi] ~= ym[mi] then return false end
                    end
                end
                return true
            end
            for lk, lst in pairs(db.trashNotesList) do
                local base, prof = lk:match("^(.-)|(.-)$")
                if base and prof and prof ~= "Default" then
                    if SameList(lst, db.trashNotesList[base .. "|Default"]) then
                        db.trashNotesList[lk] = nil
                        undone = undone + 1
                    end
                end
            end
            if undone > 0 then
                self:DebugPrint("BossNotes: undid " .. undone
                    .. " sprayed Default copies from other profiles", "profile")
            end
            -- This branch deletes db.notes entries and then falls into the
            -- early return below, so it must drop the lookup index itself -
            -- the invalidate at the end of this function is not reached.
            self:InvalidateBossNoteIndex()
        end

        if db.profileIsolationRepaired2 then return end
        db.profileIsolationRepaired2 = true

        local longs = { "Molten Core", "Blackwing Lair", "Temple of Ahn'Qiraj",
            "Naxxramas", "Zul'Gurub", "Onyxia's Lair", "Ruins of Ahn'Qiraj" }

        local repaired = 0

        local seeds = {}
        for k, v in pairs(db.notes) do
            if type(k) == "string" and v and v ~= "" then
                local mob, _, prof = k:match("^(.-)|(.-)|(.-)$")
                if mob and prof == "Default" and (not seeds[mob] or #v > #seeds[mob]) then
                    seeds[mob] = v
                end
            end
        end
        for mob, v in pairs(seeds) do
            for _, rl in ipairs(longs) do
                local sk = mob .. "|" .. rl .. "|Default"
                if not db.notes[sk] or db.notes[sk] == "" then
                    db.notes[sk] = v
                    repaired = repaired + 1
                end
            end
        end

        if repaired > 0 then
            self:DebugPrint("BossNotes repair: restored " .. repaired
                .. " notes across profiles and raids", "profile")
        end

        if not db.bossNotesOrphanAdopt then
            db.bossNotesOrphanAdopt = true
            local function liveProfiles(rl)
                local rp = self.db.raidProfiles and self.db.raidProfiles[rl]
                if not (rp and type(rp.profiles) == "table" and next(rp.profiles)) then
                    return nil
                end
                local set = {}
                for pName in pairs(rp.profiles) do set[pName] = true end
                if rp.activeProfile then set[rp.activeProfile] = true end
                return set
            end
            local adopted = 0
            local copies = {}
            for k, v in pairs(db.notes) do
                if type(k) == "string" and v and v ~= "" then
                    local mob, rl, prof = k:match("^(.-)|(.-)|(.-)$")
                    if mob and prof and prof ~= "Default" then
                        local live = liveProfiles(rl)
                        if live and not live[prof] then
                            for pName in pairs(live) do
                                local nk = mob .. "|" .. rl .. "|" .. pName
                                if (not db.notes[nk] or db.notes[nk] == "")
                                   and copies[nk] == nil then
                                    copies[nk] = v
                                end
                            end
                        end
                    end
                end
            end
            for nk, v in pairs(copies) do db.notes[nk] = v; adopted = adopted + 1 end
            for short, rl in pairs(RAID_LONG_NAME_BY_KEY) do
                local live = liveProfiles(rl)
                if live then
                    local function adoptPairMap(map)
                        if type(map) ~= "table" then return end
                        local cm = {}
                        for k, v in pairs(map) do
                            local base, prof = k:match("^(.-)|(.-)$")
                            if base == short and prof and prof ~= "Default"
                               and not live[prof] and v and v ~= "" then
                                for pName in pairs(live) do
                                    local nk = short .. "|" .. pName
                                    if (map[nk] == nil or map[nk] == "") and cm[nk] == nil then
                                        cm[nk] = v
                                    end
                                end
                            end
                        end
                        for nk, v in pairs(cm) do map[nk] = v; adopted = adopted + 1 end
                    end
                    adoptPairMap(db.trashNotesByRaid)
                    local packs = db.trashNotesByPack[short]
                    if type(packs) == "table" then
                        local cm = {}
                        for k, v in pairs(packs) do
                            local base, prof = k:match("^(.-)|(.-)$")
                            if base and prof and prof ~= "Default"
                               and not live[prof] and v and v ~= "" then
                                for pName in pairs(live) do
                                    local nk = base .. "|" .. pName
                                    if (packs[nk] == nil or packs[nk] == "") and cm[nk] == nil then
                                        cm[nk] = v
                                    end
                                end
                            end
                        end
                        for nk, v in pairs(cm) do packs[nk] = v; adopted = adopted + 1 end
                    end
                    if type(db.trashNotesList) == "table" then
                        for lk, lst in pairs(db.trashNotesList) do
                            local base, prof = lk:match("^(.-)|(.-)$")
                            if base == short and prof and prof ~= "Default"
                               and not live[prof]
                               and type(lst) == "table" and #lst > 0 then
                                for pName in pairs(live) do
                                    local nk = short .. "|" .. pName
                                    local cur = db.trashNotesList[nk]
                                    if type(cur) ~= "table" or #cur == 0 then
                                        local copy = {}
                                        for i, note in ipairs(lst) do
                                            local mobs = {}
                                            for mi, m in ipairs(note.mobs or {}) do mobs[mi] = m end
                                            copy[i] = { text = note.text, mobs = mobs,
                                                kills = note.kills, dur = note.dur,
                                                trigger = note.trigger }
                                        end
                                        db.trashNotesList[nk] = copy
                                        db.trashNotesListMig[nk] = true
                                        adopted = adopted + 1
                                    end
                                end
                            end
                        end
                    end
                end
            end
            if adopted > 0 then
                self:Print(RCL["Recovered "] .. adopted
                    .. RCL[" notes that were filed under renamed profiles - they now show on your current profiles."])
            end
        end
        -- Repairs mutate db.notes without saving.
        if self.InvalidateBossNoteIndex then self:InvalidateBossNoteIndex() end
    end

    function RC:CreateBossNotesFrame()
        if self.bossNotes.frame then return end
        local db = self.db.bossNotes

        local frame = CreateFrame("Frame", "WRBossNotesFrame", UIParent, "BackdropTemplate")
        frame:SetWidth(300)
        frame:SetHeight(40)
        RC.Position.Bind(frame, function() return self.db.bossNotes end, {
            point = "CENTER", default = { x = 0, y = 150 },
        })
        RC.Position.RestoreFrame(frame)
        frame:SetFrameStrata("HIGH")
        frame:SetFrameLevel(100)
        frame:SetClampedToScreen(true)
        frame:SetMovable(true)
        frame:EnableMouse(not db.locked)
        frame:RegisterForDrag("LeftButton")

        -- Flat window fill with a 1px theme border (both the plain white
        -- pixel, vertex coloured) - the same shell as every other panel.
        local bgC = self:GetColor("ui", "windowBackground")
        local bordC = self:GetColor("ui", "borderNormal")
        local flat = (RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8"
        frame:SetBackdrop({
            bgFile   = flat,
            edgeFile = flat,
            edgeSize = 1,
        })
        frame:SetBackdropColor(bgC.r, bgC.g, bgC.b, (db.opacity or 0.85) * 0.9)
        frame:SetBackdropBorderColor(bordC.r, bordC.g, bordC.b, bordC.a or 1)
        frame.backdropSet = true

        local noteText = frame:CreateFontString(nil, "OVERLAY")
        self:ApplyCustomFont(noteText, db.fontSize or 14, "OUTLINE")
        noteText:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -6)
        noteText:SetJustifyH("LEFT")
        noteText:SetJustifyV("TOP")
        noteText:SetWordWrap(true)
        noteText:SetShadowOffset(1, -1)
        noteText:SetShadowColor(0, 0, 0, 1)
        local tc = self:GetColor("ui", "headerText")
        noteText:SetTextColor(tc.r, tc.g, tc.b, tc.a)
        frame.noteText = noteText

        RC.Position.MakeMovable(frame, function() return not db.locked end)

        frame:Hide()
        self.bossNotes.frame = frame
        if self.ApplyFrameCustom then self:ApplyFrameCustom(frame, function() return RC.db and RC.db.bossNotes end) end
        self:DebugPrint("BossNotes frame created", "system")
    end

    -- Width clamp for the note frame, in pixels.
    local BN_MAX_W = 520
    local BN_MIN_W = 100
    -- Two-pass measure: the frame is first blown out well past BN_MAX_W with
    -- wrapping off so each line's true width can be read, then clamped and
    -- re-wrapped at the result. Skipped entirely when neither the text nor
    -- the font size moved, since it is several forced layout passes.
    local function AutoSizeBossNote(frame, noteText, db)
        local nt = frame.noteText

        local fontSize = db.fontSize or 14
        if frame._lastNoteText == noteText and frame._lastNoteFontSize == fontSize
                and frame:IsShown() then
            return
        end
        frame._lastNoteText     = noteText
        frame._lastNoteFontSize = fontSize

        nt:ClearAllPoints()
        nt:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -6)
        nt:SetWordWrap(false)
        nt:SetWidth(BN_MAX_W + 400)
        frame:SetWidth(BN_MAX_W + 400)
        frame:SetHeight(200)
        frame:Show()

        local maxLineW = 0
        for line in (noteText .. "\n"):gmatch("([^\n]*)\n") do
            local measured = (line ~= "") and line or " "
            nt:SetText(measured)
            local lw = nt:GetStringWidth()
            if lw > maxLineW then maxLineW = lw end
        end

        local w = math.max(BN_MIN_W, math.min(BN_MAX_W, maxLineW + 16))

        nt:SetWordWrap(true)
        nt:SetWidth(w - 16)
        nt:SetText(noteText)
        frame:SetWidth(w)
        frame:SetHeight(1000)
        local textH = nt:GetStringHeight()
        frame:SetHeight(math.max(28, textH + 12))
    end

    -- ==================================================================
    -- ==================================================================
    -- Current storage for trash notes: db.trashNotesList["<raidKey>|<prof>"]
    -- is an ordered list of { text, mobs, kills, dur, trigger }. On first
    -- read for a raid/profile pair it folds the older blanket, per-pack and
    -- per-mob maps into that list and clears the old slots, so exactly one
    -- representation survives per pair.
    function RC:GetTrashNoteList(raidKey, prof)
        local db = self.db and self.db.bossNotes
        if not (db and raidKey and prof) then return nil end
        local key = raidKey .. "|" .. prof
        if type(db.trashNotesList[key]) ~= "table" then
            db.trashNotesList[key] = {}
        end
        local list = db.trashNotesList[key]

        if not db.trashNotesListMig[key] then
            db.trashNotesListMig[key] = true
            local packs = self.trashPacks and self.trashPacks[raidKey]
            local raidLong = RAID_LONG_NAME_BY_KEY[raidKey]
            local function CfgTake(tbl, packKey, def)
                local ck = raidKey .. "|" .. packKey .. "|" .. prof
                local v = tonumber(tbl[ck]); tbl[ck] = nil
                if not v or v < 1 then return def end
                return v
            end

            if packs then
                local bKey = raidKey .. "|" .. prof
                local bTxt = db.trashNotesByRaid[bKey]
                if bTxt and bTxt ~= "" then
                    local mobs = {}
                    for _, pack in ipairs(packs) do
                        for _, m in ipairs(pack.mobs or {}) do mobs[#mobs + 1] = m end
                    end
                    list[#list + 1] = { text = bTxt, mobs = mobs,
                        kills = CfgTake(db.trashNoteKills, "blanket", 1),
                        dur   = CfgTake(db.trashNoteDur,   "blanket", 8) }
                    db.trashNotesByRaid[bKey] = nil
                end
                local byPack = db.trashNotesByPack[raidKey]
                for _, pack in ipairs(packs) do
                    local pKey = pack.key .. "|" .. prof
                    local pTxt = byPack and byPack[pKey]
                    if pTxt and pTxt ~= "" then
                        local mobs = {}
                        for _, m in ipairs(pack.mobs or {}) do mobs[#mobs + 1] = m end
                        list[#list + 1] = { text = pTxt, mobs = mobs,
                            kills = CfgTake(db.trashNoteKills, pack.key, 1),
                            dur   = CfgTake(db.trashNoteDur,   pack.key, 8) }
                        byPack[pKey] = nil
                    end
                    if db.trashNoteAdded then
                        db.trashNoteAdded[raidKey .. "|" .. pack.key .. "|" .. prof] = nil
                    end
                end
                if raidLong then
                    for _, pack in ipairs(packs) do
                        for _, m in ipairs(pack.mobs or {}) do
                            local nKey = m .. "|" .. raidLong .. "|" .. prof
                            local nTxt = db.notes[nKey]
                            if nTxt and nTxt ~= "" then
                                list[#list + 1] = { text = nTxt, mobs = { m },
                                    trigger = "target", kills = 1, dur = 8 }
                                db.notes[nKey] = nil
                            end
                        end
                    end
                end
            end
            -- The fold above deletes db.notes entries without saving.
            self:InvalidateBossNoteIndex()
        end
        return list
    end

    local function ShowTransientTrashNote(text, dur)
        local state = RC.bossNotes
        local f = state and state.frame
        local db = RC.db and RC.db.bossNotes
        if not f or not f.noteText or not (db and db.enabled) then return end
        if RC.StyleBossNotesBox then
            f._lastStyledNote = text
            RC:StyleBossNotesBox(f, text, db)
        else
            AutoSizeBossNote(f, text, db)
        end
        ShowNote(f, db)
        -- Identity token, not a cancellable timer: a later note replaces the
        -- token so the earlier note's expiry cannot hide the new one.
        local token = {}
        f._killNoteToken = token
        C_Timer.After(dur or 8, function()
            if f._killNoteToken == token and f:IsShown() then
                HideNote(f, RC.db and RC.db.bossNotes)
            end
        end)
    end

    local function OnTrashKill(refs)
        for i = 1, #refs do
            local ref = refs[i]
            if not ref.fired then
                ref.count = ref.count + 1
                if ref.count >= ref.need then
                    ref.fired = true
                    ShowTransientTrashNote(ref.text, ref.dur)
                    RC:DebugPrint("Trash note fired after " .. ref.count
                        .. " kills (" .. (ref.label or "?") .. ")", "config")
                end
            end
        end
    end

    function RC:RebuildTrashKillWatch()
        local state = self.bossNotes
        local db = self.db and self.db.bossNotes
        local raidKey = state and state.npCurrentRaidKey
        if not (db and db.enabled and db.showForTrash and raidKey) then
            if state then state.trashTargetMap = nil end
            self:KillWatchUnregister("trashnotes")
            return
        end
        local raidLong = RAID_LONG_NAME_BY_KEY[raidKey]
        local prof = raidLong and self.GetActiveProfileNameForRaid
            and self:GetActiveProfileNameForRaid(raidLong)
        local list = prof and self:GetTrashNoteList(raidKey, prof)
        if not (list and #list > 0) then
            state.trashTargetMap = nil
            self:KillWatchUnregister("trashnotes")
            return
        end

        -- Two dispatch paths per note. trigger "target" goes into targetMap
        -- and is read on PLAYER_TARGET_CHANGED; anything else registers a
        -- kill-count ref with RC.KillWatch, the addon's single CLEU reader.
        -- One ref is shared by every mob in the note, so a note needing
        -- three kills fires once regardless of which mobs supplied them.
        local set = {}
        local targetMap = {}
        for i = 1, #list do
            local note = list[i]
            if note.text and note.text ~= "" and note.mobs and #note.mobs > 0 then
                if note.trigger == "target" then
                    for _, mob in ipairs(note.mobs) do
                        local ml = string.lower(mob)
                        if targetMap[ml] == nil then targetMap[ml] = note.text end
                    end
                else
                    local need = tonumber(note.kills); if not need or need < 1 then need = 1 end
                    local dur  = tonumber(note.dur);   if not dur  or dur  < 1 then dur  = 8 end
                    local ref = { text = note.text, need = need, dur = dur,
                                  count = 0, label = RCL["note "] .. i }
                    for _, mob in ipairs(note.mobs) do
                        local ml = string.lower(mob)
                        local bucket = set[ml]
                        if not bucket then bucket = {}; set[ml] = bucket end
                        bucket[#bucket + 1] = ref
                    end
                end
            end
        end
        state.trashTargetMap = next(targetMap) and targetMap or nil

        if next(set) then
            self:KillWatchRegister("trashnotes", set, OnTrashKill)
        else
            self:KillWatchUnregister("trashnotes")
        end
    end

    function RC:UpdateBossNotes()
        if self.bossNotes then self.bossNotes.isPreviewing = false end

        local frame = self.bossNotes.frame
        if not frame then return end

        local db = self.db.bossNotes
        if not db.enabled then
            if self.bossNotes.lingerTimer then
                self.bossNotes.lingerTimer:Cancel()
                self.bossNotes.lingerTimer = nil
            end
            HideNote(frame, db)
            return
        end

        if RC.Profiler then RC.Profiler:StartTiming("BossNotes") end

        local noteText = nil
        local target = UnitExists("target") and UnitName("target") or nil
        local targetLower = target and target:lower() or nil

        local currentRaid, activeProfile = nil, nil
        if RC.GetEffectiveRaidName then currentRaid = RC:GetEffectiveRaidName() end
        if RC.GetActiveProfileNameForRaid and currentRaid then
            activeProfile = RC:GetActiveProfileNameForRaid(currentRaid)
        end

        -- Without a live raid AND profile there is no key to build, and
        -- nothing is shown. The lowercased-key index replaces the old
        -- walk-the-whole-map-per-call comparison.
        local function LookupNote(mobLower)
            if not mobLower then return nil end
            if not (currentRaid and activeProfile) then return nil end
            local scopedKey = mobLower .. "|" .. currentRaid:lower() .. "|" .. activeProfile:lower()
            return GetBossNoteIndex(db.notes)[scopedKey]
        end

        if targetLower then
            noteText = LookupNote(targetLower)
        end

        if not noteText and RC.activeEncounterName then
            noteText = LookupNote(RC.activeEncounterName:lower())
        end

        if not noteText and db.showForTrash and targetLower then
            local m = self.bossNotes.trashTargetMap
            if m then noteText = m[targetLower] end
        end

        if noteText then
            if self.bossNotes.lingerTimer then
                self.bossNotes.lingerTimer:Cancel()
                self.bossNotes.lingerTimer = nil
            end
            self.bossNotes.lastNote = noteText
        else
            local linger = db.lingerDuration or 0
            if linger > 0 and self.bossNotes.lastNote and not self.bossNotes.lingerTimer then
                self.bossNotes.lingerTimer = C_Timer.NewTimer(linger, function()
                    self.bossNotes.lingerTimer = nil
                    self.bossNotes.lastNote = nil
                    if frame then HideNote(frame, RC.db.bossNotes) end
                end)
                if RC.Profiler then RC.Profiler:StopTiming("BossNotes") end
                return
            end
            if self.bossNotes.lingerTimer then
                self.bossNotes.lingerTimer:Cancel()
                self.bossNotes.lingerTimer = nil
            end
            self.bossNotes.lastNote = nil
            self.bossNotes._lastSpokenNote = nil
            self.bossNotes._noteSpokenAtEncounter = nil
            HideNote(frame, db)
            if RC.Profiler then RC.Profiler:StopTiming("BossNotes") end
            return
        end

        if self.StyleBossNotesBox then
            if frame._lastStyledNote ~= noteText or not frame:IsShown() then
                frame._lastStyledNote = noteText
                self:StyleBossNotesBox(frame, noteText, db)
            end
        else
            self:ApplyCustomFont(frame.noteText, db.fontSize or 14, "OUTLINE")
            local noteC = self:GetColor("text", "white")
            frame.noteText:SetTextColor(noteC.r, noteC.g, noteC.b, noteC.a or 1)
            AutoSizeBossNote(frame, noteText, db)
        end

        if db.ttsEnabled and C_VoiceChat and C_VoiceChat.SpeakText then
            local trigger = db.ttsTrigger or "encounter_start"
            local shouldSpeak = false

            if trigger == "encounter_start" then
                local enc = RC.activeEncounterName or UnitName("target") or "unknown"
                shouldSpeak = (self.bossNotes._noteSpokenAtEncounter ~= enc) or
                              (self.bossNotes._lastSpokenNote ~= noteText)
                if shouldSpeak then
                    self.bossNotes._noteSpokenAtEncounter = enc
                end
            else
                shouldSpeak = (self.bossNotes._lastSpokenNote ~= noteText)
            end

            if shouldSpeak then
                self.bossNotes._lastSpokenNote = noteText
                -- Strip colour escapes before speaking, or the voice reads
                -- the hex codes out.
                local plainText = noteText:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                if self.SpeakTTS then
                    self:SpeakTTS(plainText, true)
                    self:DebugPrint("BossNotes TTS: speaking note for " .. (RC.activeEncounterName or "target"), "system")
                end
            end
        end

        if not self.StyleBossNotesBox then
            local opacity = db.opacity or 0.85
            if db.showBackground then
                local bgC = self:GetColor("ui", "windowBackground")
                frame:SetBackdropColor(bgC.r, bgC.g, bgC.b, opacity * 0.9)
                frame:SetBackdropBorderColor(0, 0, 0, 1)
            else
                frame:SetBackdropColor(0, 0, 0, 0)
                frame:SetBackdropBorderColor(0, 0, 0, 0)
            end
        end

        frame:EnableMouse(not db.locked)
        if RC.Profiler then RC.Profiler:StopTiming("BossNotes") end
        ShowNote(frame, db)
    end

    function RC:ApplyBossNotesPosition()
        local frame = self.bossNotes.frame
        if not frame then return end
        local db = self.db.bossNotes
        RC.Position.RestoreFrame(frame)
        frame:EnableMouse(not db.locked)
        -- layer / scale / clamp, fade rules, shadow / glow (the standard)
        if self.ApplyFrameCustom then self:ApplyFrameCustom(frame, function() return RC.db and RC.db.bossNotes end) end
    end

    function RC:HideBossNotesPreview()
        if self.bossNotes then self.bossNotes.isPreviewing = false end
        if self.bossNotes.frame then self.bossNotes.frame:Hide() end
    end

    function RC:PreviewBossNoteText(noteText)
        local frame = self.bossNotes.frame
        if not frame then return end

        if frame:IsShown() and self.bossNotes.isPreviewing
           and self.bossNotes.previewingText == noteText then
            self:HideBossNotesPreview()
            return
        end

        local db = self.db.bossNotes
        if self.StyleBossNotesBox then
            frame._lastStyledNote = noteText
            self:StyleBossNotesBox(frame, noteText, db)
        else
            self:ApplyCustomFont(frame.noteText, db.fontSize or 14, "OUTLINE")
            local tc = self:GetColor("ui", "headerText")
            frame.noteText:SetTextColor(tc.r, tc.g, tc.b, tc.a or 1)
            AutoSizeBossNote(frame, noteText, db)
            local opacity = db.opacity or 0.85
            if db.showBackground then
                local bgC = self:GetColor("ui", "windowBackground")
                frame:SetBackdropColor(bgC.r, bgC.g, bgC.b, opacity * 0.9)
                frame:SetBackdropBorderColor(0, 0, 0, 1)
            else
                frame:SetBackdropColor(0, 0, 0, 0)
                frame:SetBackdropBorderColor(0, 0, 0, 0)
            end
        end
        frame:EnableMouse(not db.locked)
        ShowNote(frame, db)
        self.bossNotes.isPreviewing = true
        self.bossNotes.previewingText = noteText
    end

    -- WRN3 text format: a version line, then one record per line.
    --   <key>\t<note>                              boss note
    --   __raid:<raidKey|prof>\t<note>              blanket trash note (legacy map)
    --   __pack:<raidKey>:<packKey|prof>\t<note>    per-pack trash note (legacy map)
    --   __list:<raidKey|prof>\t<trigger>\t<kills>\t<dur>\t<mob;mob;...>\t<text>
    -- The __list records (new in WRN3) carry db.trashNotesList, the current
    -- trash-note storage, which WRN2 silently dropped. Tabs, newlines and
    -- returns are flattened to spaces because the tab is the field separator
    -- and the newline the record separator; mob names also flatten ";".
    function RC:ExportBossNotes()
        local db = self.db.bossNotes
        local parts = {"WRN3"}

        for name, note in pairs(db.notes or {}) do
            if type(name) == "string" and type(note) == "string" and note ~= "" then
                parts[#parts+1] = name:gsub("[\t\n\r]", " ") .. "\t" .. note:gsub("[\t\n\r]", " ")
            end
        end

        for raidKey, note in pairs(db.trashNotesByRaid or {}) do
            if type(note) == "string" and note ~= "" then
                parts[#parts+1] = "__raid:" .. raidKey .. "\t" .. note:gsub("[\t\n\r]", " ")
            end
        end

        for raidKey, packs in pairs(db.trashNotesByPack or {}) do
            if type(packs) == "table" then
                for packKey, note in pairs(packs) do
                    if type(note) == "string" and note ~= "" then
                        parts[#parts+1] = "__pack:" .. raidKey .. ":" .. packKey ..
                                          "\t" .. note:gsub("[\t\n\r]", " ")
                    end
                end
            end
        end

        for listKey, list in pairs(db.trashNotesList or {}) do
            if type(listKey) == "string" and type(list) == "table" then
                for _, note in ipairs(list) do
                    if type(note) == "table" and type(note.text) == "string"
                       and note.text ~= "" then
                        local mobs = {}
                        for mi, m in ipairs(note.mobs or {}) do
                            mobs[mi] = tostring(m):gsub("[\t\n\r;]", " ")
                        end
                        parts[#parts+1] = "__list:" .. listKey:gsub("[\t\n\r]", " ")
                            .. "\t" .. tostring(note.trigger or "kills")
                            .. "\t" .. tostring(tonumber(note.kills) or 1)
                            .. "\t" .. tostring(tonumber(note.dur) or 8)
                            .. "\t" .. table.concat(mobs, ";")
                            .. "\t" .. note.text:gsub("[\t\n\r]", " ")
                    end
                end
            end
        end

        if #parts == 1 then return "" end
        return table.concat(parts, "\n")
    end

    function RC:ImportBossNotes(str)
        if not str or type(str) ~= "string" then return false, "Empty input" end
        str = str:match("^%s*(.-)%s*$")
        if not (str:match("^WRN3") or str:match("^WRN2") or str:match("^WRN1")) then
            return false, "Not a valid WRN1/WRN2/WRN3 note string"
        end

        local db = self.db.bossNotes
        if not db.notes then db.notes = {} end
        if not db.trashNotesByRaid then db.trashNotesByRaid = {} end
        if not db.trashNotesByPack then db.trashNotesByPack = {} end
        if type(db.trashNotesList)    ~= "table" then db.trashNotesList    = {} end
        if type(db.trashNotesListMig) ~= "table" then db.trashNotesListMig = {} end

        local lines = {}
        for line in (str .. "\n"):gmatch("([^\n\r]*)\r?\n") do
            lines[#lines+1] = line
        end

        -- Unscoped keys (WRN1 strings predate profile scoping) go through
        -- the same logic as the login profile-isolation migration: the note
        -- is copied to every raid/profile slot that is empty, and never
        -- overwrites anything. Scoped keys keep the direct overwrite the
        -- importer has always done.
        local allRaidKeys = {"mc","bwl","aq40","naxx","zg","onyxia","aq20"}

        local function ScopeBossNote(mobKey, note)
            for _, k in ipairs(allRaidKeys) do
                local raidLong = RAID_LONG_NAME_BY_KEY[k]
                for _, prof in ipairs(ProfilesFor(raidLong)) do
                    local scoped = mobKey .. "|" .. raidLong .. "|" .. prof
                    if not db.notes[scoped] or db.notes[scoped] == "" then
                        db.notes[scoped] = note
                    end
                end
            end
        end

        local function ScopeRaidNote(raidKey, note)
            for _, prof in ipairs(ProfilesFor(RAID_LONG_NAME_BY_KEY[raidKey] or "")) do
                local scoped = raidKey .. "|" .. prof
                if not db.trashNotesByRaid[scoped] or db.trashNotesByRaid[scoped] == "" then
                    db.trashNotesByRaid[scoped] = note
                end
            end
        end

        local function ScopePackNote(raidKey, packKey, note)
            db.trashNotesByPack[raidKey] = db.trashNotesByPack[raidKey] or {}
            local packs = db.trashNotesByPack[raidKey]
            for _, prof in ipairs(ProfilesFor(RAID_LONG_NAME_BY_KEY[raidKey] or "")) do
                local scoped = packKey .. "|" .. prof
                if not packs[scoped] or packs[scoped] == "" then
                    packs[scoped] = note
                end
            end
        end

        local count = 0
        for i = 2, #lines do
            local line = lines[i]
            if line and line ~= "" then
                local tab = line:find("\t")
                if tab then
                    local name = line:sub(1, tab - 1)
                    local note = line:sub(tab + 1)
                    if name ~= "" and note ~= "" then
                        if name == "__trash__" then
                            for _, k in ipairs({"mc","bwl","aq40","naxx","zg","onyxia"}) do
                                ScopeRaidNote(k, note)
                            end
                            count = count + 1
                        else
                            local listKey = name:match("^__list:(.+)$")
                            local raidK = name:match("^__raid:(.+)$")
                            local rk, pk = name:match("^__pack:([^:]+):(.+)$")
                            if listKey then
                                -- WRN3 trash-note-list record. Merge-only:
                                -- a note whose text already exists in the
                                -- target list is skipped, so re-imports
                                -- never duplicate.
                                local trigger, kills, dur, mobsStr, text = note:match(
                                    "^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
                                if text and text ~= "" then
                                    local list = db.trashNotesList[listKey]
                                    if type(list) ~= "table" then
                                        list = {}
                                        db.trashNotesList[listKey] = list
                                    end
                                    db.trashNotesListMig[listKey] = true
                                    local dup = false
                                    for _, ex in ipairs(list) do
                                        if type(ex) == "table" and ex.text == text then
                                            dup = true
                                            break
                                        end
                                    end
                                    if not dup then
                                        local mobs = {}
                                        for m in mobsStr:gmatch("[^;]+") do
                                            m = m:match("^%s*(.-)%s*$")
                                            if m ~= "" then mobs[#mobs + 1] = m end
                                        end
                                        list[#list + 1] = {
                                            text    = text,
                                            mobs    = mobs,
                                            kills   = tonumber(kills) or 1,
                                            dur     = tonumber(dur) or 8,
                                            trigger = (trigger ~= "" and trigger) or "kills",
                                        }
                                        count = count + 1
                                    end
                                end
                            elseif raidK then
                                if raidK:find("|", 1, true) then
                                    db.trashNotesByRaid[raidK] = note
                                else
                                    ScopeRaidNote(raidK, note)
                                end
                                count = count + 1
                            elseif rk and pk then
                                if pk:find("|", 1, true) then
                                    db.trashNotesByPack[rk] = db.trashNotesByPack[rk] or {}
                                    db.trashNotesByPack[rk][pk] = note
                                else
                                    ScopePackNote(rk, pk, note)
                                end
                                count = count + 1
                            else
                                if name:find("|", 1, true) then
                                    db.notes[name] = note
                                else
                                    ScopeBossNote(name, note)
                                end
                                count = count + 1
                            end
                        end
                    end
                end
            end
        end

        self:InvalidateBossNoteIndex()
        self:SaveConfigurationToProfile()
        return true, count
    end

    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    eventFrame:RegisterEvent("ENCOUNTER_START")
    eventFrame:RegisterEvent("ENCOUNTER_END")

    eventFrame:SetScript("OnEvent", function(_, event, ...)
        if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
            if RC.RepairBossNoteProfiles then RC:RepairBossNoteProfiles() end
            RC.bossNotes.npCurrentRaidKey = DetectCurrentRaidKey()
            RC:RebuildTrashKillWatch()
            C_Timer.After(1, function() RC:UpdateBossNotes() end)

        elseif event == "ENCOUNTER_START" then
            if RC.db and RC.db.bossNotes and RC.db.bossNotes.enabled then
                RC:UpdateBossNotes()
            end

        elseif event == "ENCOUNTER_END" then
            if RC.UpdateBossNotes then RC:UpdateBossNotes() end

        else
            RC:UpdateBossNotes()
        end
    end)

    RC:InitializeBossNotesDB()
    RC:CreateBossNotesFrame()
    RC.bossNotes.npCurrentRaidKey = DetectCurrentRaidKey()

    RC:DebugPrint("BossNotes module loaded (v2: per-raid/per-pack/nameplate)", "system")
end

C_Timer.After(0.5, InitializeBossNotes)
