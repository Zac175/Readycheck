------------------------------------------------------------------------
-- Readycheck - Text-to-Speech Engine
-- Owns the C_VoiceChat speak queue/global cooldown, voice selection,
-- spoken-name shortening, and the consumable expiry voice watch.
--
-- Lives in the main addon, not Readycheck_Consumables, because the
-- reminder stack speaks through it too (RR_Engine alone has 13 call
-- sites) and reminders must not fall silent because the consumable bars
-- were switched off in the AddOns list.
--
-- Ran inside an RC._chInit closure while it lived in the Consumables
-- folder. Nothing in the body reads RC.db at load time - only the
-- functions do, at call time - so it runs as a plain do-block here and
-- publishes into RC._chs before any Consumables closure drains.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local GetItemSpell = GetItemSpell or (RCC and RCC.Compat and RCC.Compat.GetItemSpell)
local UnitAura = UnitAura or (RCC and RCC.Compat and RCC.Compat.UnitAura)
local WRF = _G.Readycheck
if not WRF then return end
WRF._chs = WRF._chs or {}
do
    local RC = _G.Readycheck
    local GetTime = GetTime
    local GetItemCount = GetItemCount or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemCount)
    local GetItemIcon = GetItemIcon or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemIcon)
    local UnitBuff = UnitBuff or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.UnitBuff)
    local GetWeaponEnchantInfo = GetWeaponEnchantInfo
    local IsInInstance = IsInInstance
    local IsInRaid = IsInRaid
    local IsResting = IsResting
    local InCombatLockdown = InCombatLockdown
    local UnitGetTotalAbsorbs = UnitGetTotalAbsorbs
    local UnitGUID = UnitGUID
    local UnitCastingInfo = UnitCastingInfo
    local UnitChannelInfo = UnitChannelInfo
    local GetSpellCooldown = GetSpellCooldown or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetSpellCooldown)
    local math_floor = math.floor
    local math_ceil = math.ceil
    local math_max = math.max
    local math_min = math.min
    local math_abs = math.abs
    local string_format = string.format
    local string_lower = string.lower
    local pairs = pairs
    local ipairs = ipairs
    local type = type

    local _chs = WRF._chs
    local function SmoothSetSize(frame, targetW, targetH)
        if not frame then return end
        if InCombatLockdown() then return end
        if frame._sizeAnim then frame._sizeAnim:Cancel(); frame._sizeAnim = nil end
        frame:SetSize(math_max(1, targetW), math_max(1, targetH))
        frame._sizeInitialized = true
    end

    local _ttsVoiceId  = 0
    local _lastLineText, _lastLineAt = nil, 0
    local _ttsVoiceChecked = false
    local ValidTtsVoice
    local _ttsDest
    local function TtsDest()
        -- EMPIRICAL (user-verified on 1.15.9): destination 0 plays at full
        -- volume; the enum-resolved LocalPlayback route is the suppressed one.
        return 0
    end
    -- ARG ORDER (user-proven on this client): SpeakText arg 4 is VOLUME,
    -- arg 5 is rate. Rate 0 means zero-speed under multiplier semantics; use 1.
    local TTS_RATE = 1
    local function CleanSpokenText(text)
        if type(text) ~= "string" then return text end
        text = text:gsub("|T.-|t", " ")
        text = text:gsub("|A.-|a", " ")
        text = text:gsub("|H.-|h(.-)|h", "%1")
        text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        return text
    end
    -- Always pushes 100: per-line loudness is the volume arg to SpeakText
    -- itself; the system speech volume is maxed so it never scales lines down.
    local function PushTtsSystemVolume()
        if C_TTSSettings and C_TTSSettings.SetSpeechVolume then
            pcall(C_TTSSettings.SetSpeechVolume, 100)
        end
        if C_VoiceChat and C_VoiceChat.SetOutputVolume then
            pcall(C_VoiceChat.SetOutputVolume, 100)
        end
    end
    local _ttsLastFire = 0
    -- Minimum gap between spoken lines so overlapping buff/stone/trinket
    -- announcements queue and play in order instead of clipping each other.
    local TTS_GLOBAL_CD = 3

    local _ttsQueue    = {}
    -- who queued each line (parallel to _ttsQueue): "route" for the raid
    -- route's lines, nil for everything else. RC:StopTTS("route") drops
    -- only those, so a route step finishing no longer swallows a
    -- consumable or reminder line that happened to be waiting.
    local _ttsQueueSrc = {}
    -- and by when it must be said (parallel too): a "say it now" line
    -- (ability reminders, Battle Shout, custom reminders...) that meets
    -- another line in progress used to be DROPPED, and its reminder still
    -- counted it as said. It now goes to the front of the queue and is
    -- said within UNQ_WAIT seconds, or let go if it could not be by then
    -- (a late "Death Wish" is worse than none).
    local _ttsQueueDl = {}
    local UNQ_WAIT = 4
    local _ttsDraining = false
    -- Another addon's voice line (a boss-mod or UI alert calling
    -- C_VoiceChat.SpeakText itself) cuts off whatever is being said. The
    -- hook further down notes when one starts: our queued lines wait for
    -- it, and a line of ours it cut short is said once more after it.
    local EXT_GAP = 2
    local _extLastFire = 0
    local _ownSpeak = false
    local _ownStop = false
    -- Readycheck_Testing's decision log, when it is loaded (no-op otherwise)
    local function Diag(fmt, ...)
        if RC.DiagLog then RC:DiagLog("tts", fmt, ...) end
    end
    -- About how long a line of ours takes to say: another addon's line or
    -- stop inside that window cut it short.
    local function SayTime(text)
        local n = 0
        for _ in tostring(text or ""):gmatch("%S+") do n = n + 1 end
        return math_min(5, 0.9 + 0.4 * n)
    end
    local _lastOwn
    local _lastLineSrc
    local _drainHeldSince
    -- DID IT PLAY? The game reports each line it actually starts speaking
    -- (VOICE_CHAT_TTS_PLAYBACK_STARTED). Every line of ours is checked a
    -- moment later: none started, and nobody else spoke in between, means
    -- the game took the line and never played it - logged, and said once
    -- more. The retry only arms once a start has been seen this session,
    -- so a client that never reports starts cannot double every line.
    local _ttsStarted = 0
    local _startsSeen = false
    local RequeueOwn
    local function CheckPlayed(lo)
        if not lo then return end
        local mark = _ttsStarted
        C_Timer.After(2, function()
            if _ttsStarted ~= mark then return end
            if _extLastFire >= lo.at then return end
            Diag("NOT played by the game: %s%s", tostring(lo.text), _startsSeen and "" or " (starts not reported yet)")
            if _startsSeen and not lo.failRetried and RC.db and RC.db.ttsEnabled and RequeueOwn then
                lo.failRetried = true
                RequeueOwn(lo)
            end
        end)
    end
    local function OwnSpeak(text, src, vol)
        _ownSpeak = true
        pcall(C_VoiceChat.SpeakText, (ValidTtsVoice and ValidTtsVoice()) or _ttsVoiceId, text, TtsDest(), vol, TTS_RATE)
        _ownSpeak = false
        local prev, now = _lastOwn, GetTime()
        _lastOwn = { text = text, src = src, at = now }
        -- a line said again keeps its marks: one retry per cause, ever
        if prev and prev.text == text and (now - prev.at) < 20 then
            _lastOwn.retried, _lastOwn.failRetried = prev.retried, prev.failRetried
        end
        _lastLineSrc = src
        Diag("said: %s%s", tostring(text), src and (" [" .. tostring(src) .. "]") or "")
        CheckPlayed(_lastOwn)
    end
    -- Raised only when a preview line is actually enqueued. A preview is
    -- allowed past the master gate on purpose, so the dump below must not
    -- swallow it on the way out. Cleared whenever the queue empties.
    local _ttsQueueHasPreview = false
    -- True only for the duration of one SpeakTTSPreview -> _SpeakTTSInner call.
    local _previewCall = false

    local function _DrainTTSQueue()
        if #_ttsQueue == 0 then
            _ttsDraining = false
            _ttsQueueHasPreview = false
            return
        end
        -- another addon is mid-line: let it finish - but never wait more
        -- than a few seconds in all, or non-stop speech elsewhere (a busy
        -- raid's narrated chat) would hold our lines for ever
        local waitExt = EXT_GAP - (GetTime() - _extLastFire)
        if waitExt > 0.05 and (GetTime() - (_drainHeldSince or GetTime())) < 6 then
            _drainHeldSince = _drainHeldSince or GetTime()
            C_Timer.After(waitExt, _DrainTTSQueue)
            return
        end
        _drainHeldSince = nil
        -- The master toggle can flip while lines are still queued. Drop the
        -- backlog rather than letting it drain after the user switched TTS
        -- off, which is what "silence it now" means to them.
        if not (RC.db and RC.db.ttsEnabled) and not _ttsQueueHasPreview then
            for i = #_ttsQueue, 1, -1 do _ttsQueue[i] = nil end
            for i = #_ttsQueueSrc, 1, -1 do _ttsQueueSrc[i] = nil end
            for i = #_ttsQueueDl, 1, -1 do _ttsQueueDl[i] = nil end
            _ttsDraining = false
            return
        end
        _ttsDraining = true
        local text = table.remove(_ttsQueue, 1)
        local src = table.remove(_ttsQueueSrc, 1)
        local dl = table.remove(_ttsQueueDl, 1)
        if src == false then src = nil end
        if dl and GetTime() > dl then
            -- a "say it now" line whose moment has passed: on to the next
            if RC._ttsTrace then RC:Print("|cFFFF6060TTS too late, let go:|r " .. tostring(text)) end
            return _DrainTTSQueue()
        end
        if RC._ttsTrace and text then
            RC:Print(RCL["|cFF60FF60TTS drain>|r "] .. tostring(text))
        end
        if C_VoiceChat and C_VoiceChat.SpeakText and text then
            local vol = (RC.db and RC.db.consumablesHelper and RC.db.consumablesHelper.consumableTTSVolume) or 100
            _ttsLastFire = GetTime()
            text = CleanSpokenText(text)
            _lastLineText, _lastLineAt = text, _ttsLastFire
            PushTtsSystemVolume()
            OwnSpeak(text, src, vol)
        end
        C_Timer.After(TTS_GLOBAL_CD, _DrainTTSQueue)
    end

    -- Someone else's voice line: noted so ours wait for it, and a line of
    -- ours it cut off in its first moments (our lines are a word or two)
    -- goes back to the front of the queue, once.
    if C_VoiceChat and type(C_VoiceChat.SpeakText) == "function" then
        hooksecurefunc(C_VoiceChat, "SpeakText", function(_, extText)
            if _ownSpeak then return end
            local now = GetTime()
            _extLastFire = now
            local lo = _lastOwn
            if RC.DiagLog then
                local who = (debugstack and debugstack(3, 3, 0) or ""):match("AddOns[/\\]([^/\\]+)") or "?"
                Diag("another addon spoke (%s): %s%s", who, tostring(extText),
                    (lo and (now - lo.at) < SayTime(lo.text)) and (" - over ours: " .. tostring(lo.text)) or "")
            end
            if lo and not lo.retried and (now - lo.at) < SayTime(lo.text) and RC.db and RC.db.ttsEnabled then
                lo.retried = true
                table.insert(_ttsQueue, 1, lo.text)
                table.insert(_ttsQueueSrc, 1, lo.src or false)
                table.insert(_ttsQueueDl, 1, false)
                if RC._ttsTrace then RC:Print("|cFFFFAA00TTS cut off by another addon|r - again after it: " .. tostring(lo.text)) end
                if not _ttsDraining then
                    _ttsDraining = true
                    C_Timer.After(EXT_GAP, _DrainTTSQueue)
                end
            end
        end)
    end
    -- ...and another addon STOPPING speech (a boss mod clearing its own
    -- voice) silences ours too, with nothing said in its place: a line of
    -- ours stopped while it was being said is said again, once.
    if C_VoiceChat and type(C_VoiceChat.StopSpeakingText) == "function" then
        hooksecurefunc(C_VoiceChat, "StopSpeakingText", function()
            if _ownStop then return end
            local now = GetTime()
            local lo = _lastOwn
            if not (lo and (now - lo.at) < SayTime(lo.text)) then return end
            local who = RC.DiagLog and ((debugstack and debugstack(3, 3, 0) or ""):match("AddOns[/\\]([^/\\]+)") or "?") or nil
            Diag("another addon stopped speech (%s) over ours: %s", tostring(who), tostring(lo.text))
            if lo.retried or not (RC.db and RC.db.ttsEnabled) then return end
            lo.retried = true
            table.insert(_ttsQueue, 1, lo.text)
            table.insert(_ttsQueueSrc, 1, lo.src or false)
            table.insert(_ttsQueueDl, 1, false)
            if not _ttsDraining then
                _ttsDraining = true
                C_Timer.After(0.5, _DrainTTSQueue)
            end
        end)
    end

    local FEMALE_VOICE_HINTS = {
        "female", "samantha", "victoria", "karen", "moira", "fiona",
        "zira", "hazel", "susan", "julie", "kate", "emily", "siri",
    }

    local function FindFemaleVoice()
        if not C_VoiceChat or not C_VoiceChat.GetTtsVoices then return 0 end
        local voices = C_VoiceChat.GetTtsVoices()
        if not voices then return 0 end
        for _, v in ipairs(voices) do
            if v.name then
                local lower = v.name:lower()
                for _, hint in ipairs(FEMALE_VOICE_HINTS) do
                    if lower:find(hint, 1, true) then
                        RC:DebugPrint("TTS female voice: " .. v.name .. " (id=" .. v.voiceID .. ")", "consumables")
                        return v.voiceID
                    end
                end
            end
        end
        return 0
    end

    ValidTtsVoice = function()
        if _ttsVoiceChecked then return _ttsVoiceId end
        _ttsVoiceChecked = true
        local voices = C_VoiceChat and C_VoiceChat.GetTtsVoices
            and C_VoiceChat.GetTtsVoices()
        if type(voices) == "table" and #voices > 0 then
            local want = RC.db and RC.db.consumablesHelper
                and RC.db.consumablesHelper.ttsVoiceId
            if want then
                for _, v in ipairs(voices) do
                    if v.voiceID == want then
                        _ttsVoiceId = want
                        return _ttsVoiceId
                    end
                end
                if RC._ttsTrace then
                    RC:Print(RCL["|cFFFF6060TTS voice|r saved id "] .. tostring(want)
                        .. RCL[" is not installed - switching to id "] .. "auto")
                end
            end
            for _, v in ipairs(voices) do
                if v.voiceID == _ttsVoiceId then return _ttsVoiceId end
            end
            local fallback = FindFemaleVoice()
            if RC._ttsTrace then
                RC:Print(RCL["|cFFFF6060TTS voice|r saved id "] .. tostring(_ttsVoiceId)
                    .. RCL[" is not installed - switching to id "] .. tostring(fallback))
            end
            _ttsVoiceId = fallback
        end
        return _ttsVoiceId
    end

    -- a line of ours back to the front of the queue, said next
    RequeueOwn = function(lo)
        table.insert(_ttsQueue, 1, lo.text)
        table.insert(_ttsQueueSrc, 1, lo.src or false)
        table.insert(_ttsQueueDl, 1, false)
        if not _ttsDraining then
            _ttsDraining = true
            C_Timer.After(0.5, _DrainTTSQueue)
        end
    end

    local _ttsEvt = CreateFrame("Frame")
    pcall(_ttsEvt.RegisterEvent, _ttsEvt, "VOICE_CHAT_TTS_PLAYBACK_FAILED")
    pcall(_ttsEvt.RegisterEvent, _ttsEvt, "VOICE_CHAT_TTS_PLAYBACK_STARTED")
    _ttsEvt:RegisterEvent("PLAYER_ENTERING_WORLD")
    _ttsEvt:SetScript("OnEvent", function(_, event, status, _, durationMS)
        if event == "PLAYER_ENTERING_WORLD" then
            -- the expiry watcher, once the bars' settings are in
            C_Timer.After(3, function() if RC.StartConsumableVoiceWatch then RC:StartConsumableVoiceWatch() end end)
            return
        end
        if event == "VOICE_CHAT_TTS_PLAYBACK_STARTED" then
            _ttsStarted = _ttsStarted + 1
            _startsSeen = true
            local lo = _lastOwn
            if lo and RC.DiagLog and (GetTime() - lo.at) < 2 and _extLastFire < lo.at then
                Diag("played: %s (%sms)", tostring(lo.text), tostring(durationMS or "?"))
            end
            return
        end
        Diag("game reported playback FAILED (status %s)%s", tostring(status),
            (_lastOwn and (GetTime() - _lastOwn.at) < 3) and (": " .. tostring(_lastOwn.text)) or "")
        _ttsVoiceChecked = false
        -- the line that failed is said once more, on a re-checked voice
        local lo = _lastOwn
        if lo and not lo.failRetried and (GetTime() - lo.at) < 3 and _extLastFire < lo.at
            and not _ownSpeak and RC.db and RC.db.ttsEnabled then
            lo.failRetried = true
            table.insert(_ttsQueue, 1, lo.text)
            table.insert(_ttsQueueSrc, 1, lo.src or false)
            table.insert(_ttsQueueDl, 1, false)
            if not _ttsDraining then
                _ttsDraining = true
                C_Timer.After(0.5, _DrainTTSQueue)
            end
        end
        if RC._ttsTrace then
            RC:Print(RCL["|cFFFF6060TTS playback FAILED|r status="] .. tostring(status)
                .. RCL[" - voice re-validates on the next line"])
        end
    end)

    function RC:GetCurrentTTSVoiceId()
        return _ttsVoiceId
    end

    function RC:RunTTSMatrixTest()
        if not (C_VoiceChat and C_VoiceChat.SpeakText) then
            RC:Print(RCL["TTS test: C_VoiceChat.SpeakText does not exist on this client."])
            return
        end
        local voices = (C_VoiceChat.GetTtsVoices and C_VoiceChat.GetTtsVoices()) or {}
        RC:Print(RCL["TTS test v2: "] .. #voices .. RCL[" voice(s), selected id="]
            .. tostring(_ttsVoiceId))
        for i = 1, math.min(#voices, 3) do
            local v = voices[i]
            RC:Print(RCL["  voice: id="] .. tostring(v.voiceID) .. " '" .. tostring(v.name) .. "'")
        end

        local e = Enum and Enum.VoiceTtsDestination
        local dests, dseen = {}, {}
        local function addD(val, label)
            if val ~= nil and not dseen[val] then
                dseen[val] = true
                dests[#dests + 1] = { v = val, label = label }
            end
        end
        if type(e) == "table" then
            local names = {}
            for k in pairs(e) do names[#names + 1] = k end
            table.sort(names, function(a, b) return e[a] < e[b] end)
            local parts = {}
            for _, k in ipairs(names) do
                parts[#parts + 1] = k .. "=" .. tostring(e[k])
                addD(e[k], k)
            end
            RC:Print(RCL["  enum VoiceTtsDestination: "] .. table.concat(parts, ", "))
        else
            RC:Print(RCL["  enum VoiceTtsDestination: MISSING - testing raw 0..3"])
            for d = 0, 3 do addD(d, "raw " .. d) end
        end

        local vid = _ttsVoiceId or 1
        local n = 0
        for _, d in ipairs(dests) do
            if n >= 7 then break end
            n = n + 1
            local num, dv, dl = n, d.v, d.label
            C_Timer.After(1.4 * n, function()
                RC:Print(RCL["TTS test #"] .. num .. RCL[": dest="] .. tostring(dv)
                    .. " (" .. dl .. RCL[") rate=1.2"])
                pcall(C_VoiceChat.SpeakText, vid, "test " .. num, dv, 100, 1.2)
            end)
        end

        n = n + 1
        local finalNum = n
        C_Timer.After(1.4 * n, function()
            local lp = 0
            RC:Print(RCL["TTS test #"] .. finalNum
                .. RCL[": known-good shape - voice=1 LocalPlayback rate=1.2 vol=75"])
            pcall(C_VoiceChat.SpeakText, 1, "test " .. finalNum, lp, 75, 1.2)
        end)
        RC:Print(RCL["TTS test v2: "] .. n
            .. RCL[" phrases, one per 1.4s. Note WHICH NUMBERS you hear."])
    end

    function RC:RunTTSLoop()
        if self._ttsLoopOn then
            self._ttsLoopOn = false
            RC:Print(RCL["TTS loop: stopped."])
            return
        end
        self._ttsLoopOn = true
        RC:Print(RCL["TTS loop: speaking every 2s for 30s. Open the Windows Volume Mixer and watch for the session that moves; note which DEVICE the voice plays on. Run /rc ttsloop again to stop."])
        local i = 0
        local function tick()
            if not RC._ttsLoopOn then return end
            i = i + 1
            if i > 15 then
                RC._ttsLoopOn = false
                RC:Print(RCL["TTS loop: done."])
                return
            end
            local vol = (RC.db and RC.db.consumablesHelper and RC.db.consumablesHelper.consumableTTSVolume) or 100
            PushTtsSystemVolume()
            local sysVol = "n/a"
            if C_TTSSettings and C_TTSSettings.GetSpeechVolume then
                local ok, v = pcall(C_TTSSettings.GetSpeechVolume)
                if ok then sysVol = tostring(v) end
            end
            local phrase
            if i % 2 == 0 then
                phrase = "<volume level='100'/>volume test " .. i
                RC:Print(RCL["TTS loop #"] .. i .. RCL[" (MARKUP), system speech vol="] .. sysVol)
            else
                phrase = "volume test " .. i
                RC:Print(RCL["TTS loop #"] .. i .. RCL[" (plain), system speech vol="] .. sysVol)
            end
            -- Arg order per the note above: arg 4 is VOLUME, arg 5 is rate.
            pcall(C_VoiceChat.SpeakText,
                (ValidTtsVoice and ValidTtsVoice()) or _ttsVoiceId,
                phrase, TtsDest(), vol, TTS_RATE)
            C_Timer.After(2, tick)
        end
        tick()
    end

    function RC:GetTTSVoices()
        if not C_VoiceChat or not C_VoiceChat.GetTtsVoices then return {} end
        return C_VoiceChat.GetTtsVoices() or {}
    end

    function RC:ApplyTTSVoice(voiceId)
        _ttsVoiceId = voiceId or FindFemaleVoice()
        _ttsVoiceChecked = false
    end

    -- RC:StopTTS("route") drops only the route's own lines (queued, or the
    -- one being said); RC:StopTTS() silences everything, as before.
    function RC:StopTTS(src)
        if src then
            for i = #_ttsQueue, 1, -1 do
                if _ttsQueueSrc[i] == src then
                    table.remove(_ttsQueue, i)
                    table.remove(_ttsQueueSrc, i)
                    table.remove(_ttsQueueDl, i)
                end
            end
            if _lastOwn and _lastOwn.src == src then _lastOwn.retried = true end
            if _lastLineSrc == src and (GetTime() - (_lastLineAt or 0)) < TTS_GLOBAL_CD
                and _extLastFire < (_lastLineAt or 0)
                and C_VoiceChat and C_VoiceChat.StopSpeakingText then
                _ownStop = true; pcall(C_VoiceChat.StopSpeakingText); _ownStop = false
            end
            return
        end
        if _lastOwn then _lastOwn.retried = true end
        if RC.DiagLog then
            Diag("all speech stopped by %s, %d queued dropped: %s",
                ((debugstack and debugstack(2, 2, 0) or ""):match("([%w_]+)%.lua") or "?"),
                #_ttsQueue, table.concat(_ttsQueue, " / "))
        end
        for i = #_ttsQueueSrc, 1, -1 do _ttsQueueSrc[i] = nil end
        for i = #_ttsQueueDl, 1, -1 do _ttsQueueDl[i] = nil end
        if RC._ttsTrace then
            local srcName = (debugstack(2, 1, 0) or ""):match("([%w_]+)%.lua") or "unknown"
            RC:Print("|cFFFF6060TTS STOP <" .. srcName .. RCL[">|r wiped "]
                .. #_ttsQueue .. RCL[" queued"])
        end
        for i = #_ttsQueue, 1, -1 do _ttsQueue[i] = nil end
        -- Wiping the queue retires whatever preview was in it; leaving the
        -- flag up would hold off the next master-off dump for no reason.
        _ttsQueueHasPreview = false
        if C_VoiceChat and C_VoiceChat.StopSpeakingText then
            _ownStop = true; pcall(C_VoiceChat.StopSpeakingText); _ownStop = false
        end
        _ttsLastFire = 0
        _ttsDraining = false
        if C_VoiceChat and C_VoiceChat.StopSpeakingText then
            _ownStop = true; pcall(C_VoiceChat.StopSpeakingText); _ownStop = false
        end
    end

    -- MASTER GATE. RC.db.ttsEnabled is the one switch that silences every
    -- spoken line in the addon: ability reminders, custom reminders, route
    -- steps, consumables, the potions/weapons bars, boss notes, buff-pushoff
    -- and the equipment reminder all reach the voice through here. Every
    -- per-feature toggle only narrows this further - none of them can speak
    -- past it. Keep this the single choke point; do not call
    -- C_VoiceChat.SpeakText directly from feature code.
    --
    -- Exactly three things speak outside this gate, all of them explicitly
    -- asked for by the user in that moment: the /rc ttstest and /rc ttsloop
    -- diagnostics, and RC:SpeakTTSPreview below (the Speak/Test buttons and
    -- the voice picker). They exist so the client's voice path can still be
    -- proven while alerts are switched off. Nothing automatic may join them.
    function RC:SpeakTTS(text, queued, src)
        if not (self.db and self.db.ttsEnabled) then
            if RC._ttsTrace and text then
                RC:Print("|cFFFF6060TTS blocked|r master toggle off: "
                    .. tostring(text))
            end
            return false
        end
        if RC._ttsTrace and text then
            local src = (debugstack(2, 1, 0) or ""):match("([%w_]+)%.lua")
                or "unknown"
            RC:Print("|cFFFFAA00TTS <" .. src .. ">|r " .. tostring(text))
        end
        return self:_SpeakTTSInner(text, queued, src)
    end

    -- Explicit user-initiated audition ("Speak"/"Test"/voice picker preview).
    -- Deliberately bypasses the master gate, like /rc ttstest does: clicking
    -- a preview button IS the request, and a user auditioning voices before
    -- switching TTS on would otherwise get silence with no explanation. Says
    -- once that the master toggle is off so nobody mistakes a working preview
    -- for working alerts. Never call this from automatic alert paths.
    function RC:SpeakTTSPreview(text, queued)
        if not text or text == "" then return false end
        if not (self.db and self.db.ttsEnabled) then
            self:Print(RCL["Previewing only - voice alerts are switched off. Turn on 'Enable voice alerts (TTS)' in Reminder Settings > Sound to hear this in play."])
        end
        -- _previewCall is scoped to exactly this call so _SpeakTTSInner can
        -- raise _ttsQueueHasPreview only on the branch that actually enqueues.
        -- Setting the queue flag here instead would strand it true on the five
        -- inner returns that never queue - including the common speak-now one
        -- - and a stranded flag permanently disables the master-off dump.
        _previewCall = true
        local ok = self:_SpeakTTSInner(text, queued)
        _previewCall = false
        return ok
    end

    function RC:_SpeakTTSInner(text, queued, src)
        if not C_VoiceChat or not C_VoiceChat.SpeakText then return false end
        if not text or text == "" then return false end
        local nowG = GetTime()
        -- (the expiry watcher is a single source: its lines are never
        -- a second copy of the same event, so these two do not apply)
        if src ~= "consume" then
            if text == _lastLineText and (nowG - (_lastLineAt or 0)) < 8 then
                return true
            end
            if _ttsQueue[#_ttsQueue] == text then
                return true
            end
        end
        local vol = (self.db and self.db.consumablesHelper and self.db.consumablesHelper.consumableTTSVolume) or 100
        local now = GetTime()
        local remaining = TTS_GLOBAL_CD - (now - _ttsLastFire)
        -- every line waits out another addon's line in progress
        remaining = math_max(remaining, EXT_GAP - (now - _extLastFire))
        if remaining > 0 or _ttsDraining then
            if not queued then
                -- "say it now": first in line, with a deadline
                table.insert(_ttsQueue, 1, text)
                table.insert(_ttsQueueSrc, 1, src or false)
                table.insert(_ttsQueueDl, 1, now + UNQ_WAIT)
                if _previewCall then _ttsQueueHasPreview = true end
                if not _ttsDraining then
                    _ttsDraining = true
                    C_Timer.After(math_max(remaining, 0) + 0.05, _DrainTTSQueue)
                end
                return true
            end
            if queued then
                _ttsQueue[#_ttsQueue + 1] = text
                _ttsQueueSrc[#_ttsQueue] = src or false
                _ttsQueueDl[#_ttsQueue] = false
                -- Only now is a preview line genuinely sitting in the queue,
                -- so only now may the drain's master-off dump be held back.
                if _previewCall then _ttsQueueHasPreview = true end
                if not _ttsDraining then
                    _ttsDraining = true
                    C_Timer.After(math_max(remaining, 0) + 0.05, _DrainTTSQueue)
                end
                return true
            end
            return false
        end
        _ttsLastFire = now
        text = CleanSpokenText(text)
        _lastLineText, _lastLineAt = text, now
        PushTtsSystemVolume()
        OwnSpeak(text, src, vol)
        return true
    end

    -- Full item names read out loud are slow and often ambiguous (three
    -- potions all starting "Greater..."); these overrides win before the
    -- prefix-stripping fallback in ShortenConsumableName runs.
    local EXACT_SHORT = {
        ["Dragonbreath Chili"]              = "Chili",
        ["Smoked Desert Dumplings"]         = "Dumplings",
        ["Dirge's Kickin' Chimaerok Chops"] = "Chops",
        ["Blessed Sunfruit"]                = "Sunfruit",
        ["Filled Festive Mug"]              = "Mug",
        ["Rumsey Rum Black Label"]          = "Rum",
        ["Gordok Green Grog"]               = "Grog",
        ["Juju Might"]                      = "Juju",
        ["Juju Power"]                      = "Juju",
        ["Juju Chill"]                      = "Juju",
        ["Juju Ember"]                      = "Juju",
        ["Juju Guile"]                      = "Juju",
        ["Swiftness of Zanza"]              = "Zanza",
        ["Spirit of Zanza"]                 = "Zanza",
        ["Sheen of Zanza"]                  = "Zanza",
        ["R.O.I.D.S."]                      = "Roids",
        ["Winterfall Firewater"]            = "Firewater",
        ["Mageblood Potion"]                = "Mageblood",
        ["Flask of the Titans"]             = "Titans",
        ["Flask of Supreme Power"]          = "Supreme Power",
        ["Flask of Distilled Wisdom"]       = "Wisdom",
        ["Flask of Chromatic Resistance"]   = "Chromatic",
        ["Flask of Petrification"]          = "Petrification",
        ["Elixir of the Mongoose"]          = "Mongoose",
        ["Elixir of Giants"]                = "Giants",
        ["Elixir of Fortitude"]             = "Fortitude",
        ["Elixir of Superior Defense"]      = "Defense",
        ["Elixir of Greater Firepower"]     = "Firepower",
        ["Elixir of Firepower"]             = "Firepower",
        ["Elixir of Frost Power"]           = "Frost Power",
        ["Elixir of Shadow Power"]          = "Shadow Power",
        ["Elixir of Poison Resistance"]     = "Poison Resist",
        ["Greater Arcane Elixir"]           = "Arcane",
        ["Mighty Rage Potion"]              = "Rage",
        ["Great Rage Potion"]               = "Rage",
        ["Major Troll's Blood Potion"]      = "Troll's Blood",
        ["Swiftness Potion"]                = "Swiftness",
        ["Free Action Potion"]              = "Free Action",
        ["Limited Invulnerability Potion"]  = "Invulnerability",
        ["Greater Stoneshield Potion"]      = "Stoneshield",
        ["Major Healing Potion"]            = "Healing",
        ["Major Mana Potion"]               = "Mana",
        ["Restorative Potion"]              = "Restorative",
        ["Greater Fire Protection Potion"]   = "Fire Protection",
        ["Greater Frost Protection Potion"]  = "Frost Protection",
        ["Greater Nature Protection Potion"] = "Nature Protection",
        ["Greater Shadow Protection Potion"] = "Shadow Protection",
        ["Greater Arcane Protection Potion"] = "Arcane Protection",
        ["Fire Protection Potion"]           = "Fire Protection",
        ["Frost Protection Potion"]          = "Frost Protection",
        ["Nature Protection Potion"]         = "Nature Protection",
        ["Shadow Protection Potion"]         = "Shadow Protection",
        ["Arcane Protection Potion"]         = "Arcane Protection",
        ["Holy Protection Potion"]           = "Holy Protection",
        ["Demonic Rune"]                    = "Rune",
        ["Dark Rune"]                       = "Rune",
        ["Elemental Sharpening Stone"]      = "Stone",
        ["Consecrated Sharpening Stone"]    = "Stone",
        ["Dense Sharpening Stone"]          = "Stone",
        ["Frost Oil"]                       = "Frost Oil",
        ["Wizard Oil"]                      = "Wizard Oil",
        ["Brilliant Wizard Oil"]            = "Wizard Oil",
        ["Superior Wizard Oil"]             = "Wizard Oil",
        ["Lesser Wizard Oil"]               = "Wizard Oil",
        ["Mana Oil"]                        = "Mana Oil",
        ["Brilliant Mana Oil"]              = "Mana Oil",
        ["Blessed Wizard Oil"]              = "Blessed Oil",
    }

    if RC.ttsSpokenNames then
        for k, v in pairs(EXACT_SHORT) do
            if RC.ttsSpokenNames[k] == nil then RC.ttsSpokenNames[k] = v end
        end
        EXACT_SHORT = RC.ttsSpokenNames
    end

    local STRIP_PREFIXES = {
        "flask of the ", "flask of ",
        "elixir of the ", "elixir of ",
        "potion of ",
        "greater arcane ", "greater ", "lesser ",
        "major ", "minor ", "superior ", "improved ",
        "filled ", "empty ", "bottled ",
    }

    local function ShortenConsumableName(name)
        if not name or name == "" then return name end

        if EXACT_SHORT[name] then return EXACT_SHORT[name] end

        local lower = name:lower()
        local result = name
        for _, pfx in ipairs(STRIP_PREFIXES) do
            if lower:sub(1, #pfx) == pfx then
                result = name:sub(#pfx + 1)
                lower  = result:lower()
                break
            end
        end
        for _, pat in ipairs({"[Pp]otion$","[Ee]lixir$","[Ff]lask$","[Dd]raught$","[Tt]onic$","[Bb]rew$"}) do
            result = result:gsub(" " .. pat, "")
        end
        local words = {}
        for w in result:gmatch("%S+") do words[#words+1] = w end
        if #words > 2 then result = words[#words] end
        return result
    end

    RC.ShortenConsumableName = ShortenConsumableName

    function RC:GetTTSName(name)
        if not name or name == "" then return name end
        return ShortenConsumableName(name)
    end

    local function IsPotionCdName(ln)
        local set = RC._potionCdNames
        if not set then
            set = {}
            local pd = RC.potionData and RC.potionData.potions
            if pd then
                for _, entry in pairs(pd) do
                    if type(entry) == "table" and entry.name
                       and not entry.noPotionCd then
                        set[string.lower(entry.name)] = true
                    end
                end
            end
            RC._potionCdNames = set
        end
        return set[ln] == true
    end

    do
        local ch = RC.db and RC.db.consumablesHelper
        if ch then
            ch.preferVoiceFiles = nil
            ch.ttsVoiceName = nil
            ch.voiceChannel = nil
            ch.pingOnQuietVoice = nil
        end
        if RC.db then RC.db.ttsMissLog = nil end
    end

    function RC:SpeakConsumableTTS(name, enabled, itemId)
        if not name or name == "" then return end
        local cdb = self.db and self.db.consumablesHelper
        -- `enabled` is the CALLING BAR's own TTS toggle and is authoritative
        -- whenever it is passed. The potions and weapons bars each own a
        -- ttsEnabled switch, so a false here has to silence that bar even
        -- while the helper bar's consumableTTSEnabled is on - OR-ing the two
        -- made those two checkboxes do nothing. Only nil (the helper bar
        -- itself, whose config table has no ttsEnabled key) falls back to
        -- consumableTTSEnabled.
        local isEnabled
        if enabled ~= nil then
            isEnabled = enabled and true or false
        else
            isEnabled = (cdb and cdb.consumableTTSEnabled) and true or false
        end
        if not isEnabled then return end
        local short = self:GetTTSName(name)
        local userText
        if itemId ~= nil and self.db and self.db.consumablesHelper then
            local ts = self.db.consumablesHelper.consumableTTSSettings
            local o = ts and ts[tostring(itemId)]
            if o and type(o.ttsText) == "string" and o.ttsText ~= "" then
                userText = o.ttsText
            end
        end
        local hasOverride = (userText ~= nil)
            or (self.ttsSpokenNames and self.ttsSpokenNames[name] ~= nil)
        if userText then short = userText end
        local ln = name:lower()
        if hasOverride then
        elseif ln:find("sharpening stone", 1, true)
                or ln:find("weightstone", 1, true)
                or ln:find("shield stone", 1, true) then
            short = "Stone"
        elseif ln:find("oil", 1, true) then
            short = "Oil"
        elseif IsPotionCdName(ln) then
            short = "Potion"
        end

        if self:SpeakTTS(short, true) then
            self:DebugPrint("SpeakConsumableTTS: " .. short, "consumables")
        else
            self:DebugPrint("SpeakConsumableTTS: TTS unavailable", "consumables")
        end
    end

    local TTS_DISABLED_BY_DEFAULT = {
        [13442] = true, -- Mighty Rage Potion: warrior-only burst, not worth an announcement
    }

    local function ItemTTSEnabled(itemId)
        if not itemId then return true end
        local s = RC.db and RC.db.consumablesHelper and RC.db.consumablesHelper.consumableTTSSettings
        local v = s and s[tostring(itemId)]
        if v then
            return v.ttsEnabled ~= false
        end
        return not TTS_DISABLED_BY_DEFAULT[itemId]
    end

    local function ItemRepeatEnabled(itemId)
        if not itemId then return true end
        local s = RC.db and RC.db.consumablesHelper and RC.db.consumablesHelper.consumableTTSSettings
        local v = s and s[tostring(itemId)]
        if v and v.repeatEnabled == false then return false end
        return true
    end

    -- "Use it again" is no help while the item is still on cooldown. Potions
    -- share one 2-minute cooldown, so a Free Action (30s), Swiftness (15s)
    -- or Limited Invulnerability (6s) buff running out - or the repeat
    -- after it - said "Potion" with nothing to drink, often while a second
    -- potion's buff was up. `by`: seconds from now the item has to be
    -- usable (the buff's time left for the expiry line, 0 for a repeat).
    -- Reads the cached bag cooldown map; synthetic bar ids never block.
    local function ItemCooldownBlocks(itemId, by)
        if type(itemId) ~= "number" or not RC.GetItemCooldownByID then return false end
        local s, d = RC:GetItemCooldownByID(itemId)
        if not (s and d and s > 0 and d > 1.5) then return false end
        return (s + d - GetTime()) > (by or 0) + 1
    end
    function RC:ConsumableCooldownBlocks(itemId, by)
        return ItemCooldownBlocks(itemId, by)
    end

    ------------------------------------------------------------------
    -- THE EXPIRY VOICE WATCHER (2026-10-22 rewrite). The one and only
    -- source of "your consumable is running out" lines.
    --
    -- It used to be spread across every bar's button refresh (four call
    -- sites) plus a sweep for items with no button, sharing a latch.
    -- Each refresh path has its own early-outs - a button showing its
    -- cooldown or the GCD, a bar frame hidden, a rebuild in progress, a
    -- refresh skipped until "the next threshold" - and wherever the
    -- line's moment fell into one of those, nobody said it: a potion
    -- whose buff ran out while the potion was on cooldown never spoke,
    -- a short buff whose window opened after the long ones' did not
    -- either. Buttons now only draw; this decides what is said.
    --
    -- Every half second (one tracked ticker): one read of your buffs and
    -- your weapon enchants, compared with what is on your bars.
    --   * A buff is ARMED once it is seen with more time left than its
    --     warning lead; it speaks once when it then drops inside the lead.
    --     Re-applying it (time left jumps up) re-arms it.
    --   * The lead is the bar's "show before expiry", narrowed for short
    --     buffs to a tenth of their duration (never under 5s).
    --   * Only running out at its own end time is an expiry. Gone with
    --     any time still on it (death, a dispel, a cancel, a rival
    --     consume pushing it off, a weapon enchant replaced) is not:
    --     nothing is said and nothing repeats - even inside the lead.
    --   * Repeats: after it has run out, the line again every repeat
    --     interval, as many times as set, until it is back - each item on
    --     its own clock, never while you are dead, never while the item is
    --     still on cooldown, never while a rival from its group is up.
    --   * The same application blinking out and back (a loading screen,
    --     an entry rebuilt) carries on where it was: never said twice.
    --   * Lines due in the same moment are said together ("Mongoose,
    --     Juju"), each word once.
    --   * Right after a login or /reload, a buff already inside its lead
    --     speaks once (it was never seen above it).
    -- Owners: an item speaks under the bar it lives on (potions bar,
    -- weapons bar, or the consumables bar), with that bar's TTS switch,
    -- its "show before expiry", its zone visibility, its hidden list, and
    -- the item's own TTS / repeat checkboxes.
    ------------------------------------------------------------------
    local VW = { state = {}, entries = nil, byBuff = nil, byName = nil, builtAt = 0,
                 present = {}, presentBd = {}, due = {}, dueSeen = {}, mem = {} }
    RC._voiceWatch = VW
    local VW_TICK, VW_REBUILD = 0.5, 5

    -- What would be said for this item (custom text, short names), or nil.
    function RC:ConsumableSpokenText(name, itemId)
        if not name or name == "" then return nil end
        local short = self:GetTTSName(name)
        local userText
        if itemId ~= nil and self.db and self.db.consumablesHelper then
            local ts = self.db.consumablesHelper.consumableTTSSettings
            local o = ts and ts[tostring(itemId)]
            if o and type(o.ttsText) == "string" and o.ttsText ~= "" then userText = o.ttsText end
        end
        local hasOverride = (userText ~= nil) or (self.ttsSpokenNames and self.ttsSpokenNames[name] ~= nil)
        if userText then short = userText end
        local ln = name:lower()
        if hasOverride then
        elseif ln:find("sharpening stone", 1, true) or ln:find("weightstone", 1, true) or ln:find("shield stone", 1, true) then
            short = "Stone"
        elseif ln:find("oil", 1, true) then
            short = "Oil"
        elseif IsPotionCdName(ln) then
            short = "Potion"
        end
        return short
    end

    -- The bar's TTS switch: an explicit true/false on the potions and
    -- weapons bars, the consumables bar's consumableTTSEnabled otherwise.
    local function ChannelOn(channel)
        if channel ~= nil then return channel and true or false end
        local cdb = RC.db and RC.db.consumablesHelper
        return (cdb and cdb.consumableTTSEnabled) and true or false
    end

    local SHARP = { "sword", "axe", "mace", "dagger", "polearm", "fist", "staff", "stave" }
    local function Sharpenable(invSlot)
        local link = GetInventoryItemLink and GetInventoryItemLink("player", invSlot)
        if not link then return false end
        local _, _, _, _, _, _, sub, _, _, _, _, classId = GetItemInfo(link)
        if classId ~= 2 or not sub then return false end
        sub = sub:lower()
        for _, w in ipairs(SHARP) do
            if (invSlot == 16 or (w ~= "polearm" and w ~= "staff" and w ~= "stave")) and sub:find(w, 1, true) then return true end
        end
        return false
    end

    local function BarVisible(bar, dbt)
        local chs = WRF._chs
        if not (dbt and dbt.enabled) then return false end
        if chs and chs.EvalBarVisibility and chs.RaidsCityMode and bar then
            return chs.EvalBarVisibility(bar, dbt, chs.RaidsCityMode) and true or false
        end
        return true
    end

    -- Who says what: rebuilt every few seconds (settings, bags, gear).
    local function BuildEntries()
        local entries, byBuff, byName, namedList = {}, {}, {}, {}
        local db = RC.db
        local cdb, pdb, wdb = db and db.consumablesHelper, db and db.potionsBar, db and db.weaponsBar
        -- owned by a bar that is ON; whether it shows in this zone is asked
        -- when a line is due, so a buff is watched before you zone in
        local helperOn = cdb and cdb.enabled
        local potionsOn = pdb and pdb.enabled
        local weaponsOn = wdb and wdb.enabled
        local function hidden(t, id) return t and t.hiddenItems and t.hiddenItems[id] end
        local isOil = RC.IsWeaponOilItem and function(id) return RC:IsWeaponOilItem(id) end or function() return false end
        local function addBuff(itemId, itemData)
            local buffId = RC.GetConsumableBuffId and RC:GetConsumableBuffId(itemId) or (itemData and itemData.buffId)
            if not buffId or itemData.enchantId or itemData.noBar then return end
            local onPotions = RC.potionBarItems and RC.potionBarItems[itemId]
            local both = RC.bothBarsItems and RC.bothBarsItems[itemId]
            local owner
            if onPotions and potionsOn and not hidden(pdb, itemId) then
                owner = { channel = pdb.ttsEnabled, lead = pdb.showBeforeExpiry or 60, bar = "potions" }
            elseif (not onPotions or both) and helperOn and not hidden(cdb, itemId) and not isOil(itemId) then
                owner = { channel = nil, lead = cdb.showBeforeExpiry or 60, bar = "helper" }
            end
            if not owner then return end
            local key = "b" .. buffId
            local e = byBuff[buffId]
            if e then
                -- two items, one buff: say the one in the bags
                if (GetItemCount(itemId) or 0) > 0 and (GetItemCount(e.itemId) or 0) == 0 then
                    e.itemId, e.name = itemId, itemData.name
                end
                return
            end
            e = { key = key, buffId = buffId, itemId = itemId, name = itemData.name,
                  channel = owner.channel, lead = owner.lead, bar = owner.bar }
            entries[key] = e
            byBuff[buffId] = e
            local nm = RC._buffNameById and RC._buffNameById[buffId]
            if nm and not byName[nm] then byName[nm] = e end
            -- matched by name only (Forever food): every row of that name
            if nm and buffId < 0 then
                namedList[nm] = namedList[nm] or {}
                table.insert(namedList[nm], e)
            end
        end
        for _, cat in pairs(RC.raidConsumables or {}) do
            if type(cat) == "table" and cat.items then
                for itemId, itemData in pairs(cat.items) do
                    if type(itemData) == "table" then addBuff(itemId, itemData) end
                end
            end
        end
        if cdb and type(cdb.customItems) == "table" then
            for itemId, itemData in pairs(cdb.customItems) do
                if type(itemData) == "table" and type(itemId) == "number" then addBuff(itemId, itemData) end
            end
        end
        -- the weapons: the stone / oil / poison on each hand
        for _, w in ipairs({ { key = "mh", slot = "mainhand", inv = 16, id = 999901 },
                             { key = "oh", slot = "offhand", inv = 17, id = 999902 } }) do
            if Sharpenable(w.inv) then
                local inv = GetInventoryItemID and GetInventoryItemID("player", w.inv)
                local owner
                if weaponsOn and wdb.showEquippedWeapons ~= false
                    and not (w.key == "mh" and RC.IsHordeMode and RC:IsHordeMode("weaponsBar"))
                    and not (wdb.hiddenWeapons and inv and wdb.hiddenWeapons[inv]) then
                    owner = { channel = wdb.ttsEnabled, lead = wdb.showBeforeExpiry or 60, bar = "weapons" }
                elseif helperOn and not hidden(cdb, w.id)
                    and not (w.key == "mh" and RC.IsHordeMode and RC:IsHordeMode("consumablesHelper"))
                    and not (cdb.hiddenWeapons and inv and cdb.hiddenWeapons[inv]) then
                    owner = { channel = nil, lead = cdb.showBeforeExpiry or 60, bar = "helper" }
                end
                if owner then
                    entries[w.key] = { key = w.key, slot = w.slot, itemId = w.id, weapon = true,
                                       channel = owner.channel, lead = owner.lead, bar = owner.bar }
                end
            end
        end
        -- every consumable buff id, owned or not: a spellId that belongs to
        -- a different consumable never claims an entry by name
        local tracked = {}
        for _, cat in pairs(RC.raidConsumables or {}) do
            if type(cat) == "table" and cat.items then
                for _, idata in pairs(cat.items) do
                    if type(idata) == "table" and idata.buffId then tracked[idata.buffId] = true end
                end
            end
        end
        -- when each entry first turned up: one that appears mid-session
        -- (an item un-hidden, a bar switched on) with its buff already
        -- inside the lead still gets its line
        local born = VW.born or {}
        local t0 = GetTime()
        for k in pairs(entries) do if not born[k] then born[k] = (VW.entries and t0) or 0 end end
        for k in pairs(born) do if not entries[k] then born[k] = nil end end
        VW.born = born
        VW.entries, VW.byBuff, VW.byName, VW.tracked = entries, byBuff, byName, tracked
        VW.namedList = namedList
        VW.builtAt = t0
    end

    local function KnownWeaponEnchant(id)
        local info = id and RC.temporaryWeaponEnchants and RC.temporaryWeaponEnchants[id]
        if type(info) == "table" and not info.isFishing then return info.name end
        local stone = id and RC.enchantIdToStone and RC.enchantIdToStone[id]
        if stone and RC.GetStoneName then return RC:GetStoneName(stone) end
        return nil
    end

    -- A rival from the item's conflict group is up (Spirit of Zanza over
    -- R.O.I.D.S., Firewater over Juju Might): asking for the old one again
    -- is no help - it would only push the rival off.
    local function RivalUp(e)
        if not e or e.weapon or not (RC.GetConflictGroup and RC.HasConflictGroupBuff) then return false end
        local g = RC:GetConflictGroup(e.itemId)
        if not g or g == "engineeringExplosives" then return false end
        local has, _, rid = RC:HasConflictGroupBuff(g)
        if not has then return false end
        return not (rid and RC.GetConsumableBuffId and RC:GetConsumableBuffId(rid) == e.buffId)
    end

    local function RepeatSettings()
        local cdb = RC.db and RC.db.consumablesHelper
        if not (cdb and cdb.consumableTTSRepeatEnabled) then return 0, 60 end
        local n = math_min(tonumber(cdb.consumableTTSRepeatCount) or 0, 10)
        return n, math_max(10, tonumber(cdb.consumableTTSRepeatInterval) or 60)
    end

    local BAR_OF = { helper = function() return RC.consumablesHelper, RC.db and RC.db.consumablesHelper end,
                     potions = function() return RC.potionsBar, RC.db and RC.db.potionsBar end,
                     weapons = function() return RC.weaponsBar, RC.db and RC.db.weaponsBar end }
    -- false: the owning bar does not show in this zone, so neither does its voice
    local function OwnerShows(e)
        local f = e.bar and BAR_OF[e.bar]
        if not f then return true end
        local bar, dbt = f()
        return BarVisible(bar, dbt)
    end
    -- Queues the line. Returns false only when the owning bar does not
    -- show in this zone: the caller keeps the line owed and tries again
    -- (zone into the raid with the flask already low - said on arrival).
    -- one log line per item and reason every half minute at most
    local function DiagOnce(e, why, fmt, ...)
        if not RC.DiagLog then return end
        VW.diagAt = VW.diagAt or {}
        local k = tostring(e and e.key) .. why
        local now = GetTime()
        if VW.diagAt[k] and now - VW.diagAt[k] < 30 then return end
        VW.diagAt[k] = now
        Diag(fmt, ...)
    end
    local function Due(e, st)
        local nm = st.name or e.name
        if not ChannelOn(e.channel) then DiagOnce(e, "ch", "not said, %s bar voice off: %s", tostring(e.bar), tostring(nm)) return true end
        if not ItemTTSEnabled(e.itemId) then DiagOnce(e, "item", "not said, TTS unticked for %s", tostring(nm)) return true end
        if not OwnerShows(e) then DiagOnce(e, "zone", "held, %s bar hidden here: %s", tostring(e.bar), tostring(nm)) return false end
        local text = RC:ConsumableSpokenText(st.name or e.name, e.itemId)
        if not text or text == "" then DiagOnce(e, "txt", "not said, no words for %s", tostring(nm)) return true end
        DiagOnce(e, "due", "due: %s (%s)", text, tostring(nm))
        if VW.dueSeen[text] then return true end
        VW.dueSeen[text] = true
        VW.due[#VW.due + 1] = text
        return true
    end

    local function Tick()
        VW.lastTick = GetTime()
        local db = RC.db
        if not (db and db.ttsEnabled) then return end
        -- the readers live in Readycheck_Consumables (load on demand):
        -- nothing to watch until it is in
        if not (RC.SnapshotAllBuffs and RC.HasWeaponEnchant and RC.performanceCache) then return end
        local now = GetTime()
        if not VW.entries or (now - VW.builtAt) >= VW_REBUILD then BuildEntries() end
        local entries, state = VW.entries, VW.state
        local dead = UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")
        local boot = (now - (VW.startedAt or now)) < 10
        wipe(VW.due); wipe(VW.dueSeen)

        -- what is up right now
        local present, presentBd = VW.present, VW.presentBd
        wipe(present); wipe(presentBd)
        local snap = RC.SnapshotAllBuffs and RC:SnapshotAllBuffs()
        if type(snap) == "table" then
            for sid, bd in pairs(snap) do
                local e = VW.byBuff[sid]
                if not e and bd.name then
                    local byN = VW.byName[bd.name:lower()]
                    -- a spellId tracked as a different consumable never
                    -- claims another's buff by name
                    if byN and not (VW.tracked and VW.tracked[sid]) then e = byN end
                    -- several rows share the name: the one whose stat it shows
                    local list = e and e.buffId and e.buffId < 0 and VW.namedList and VW.namedList[bd.name:lower()]
                    if list and #list > 1 and RC.ResolveNamedConsumableBuff then
                        local one = { [sid] = bd }
                        for _, cand in ipairs(list) do
                            local m = RC._namedBuffMatch and RC._namedBuffMatch[cand.buffId]
                            if m and RC:ResolveNamedConsumableBuff(one, m) then e = cand break end
                        end
                    end
                end
                if e then
                    local exp = tonumber(bd.expirationTime) or 0
                    local old = presentBd[e.key]
                    if not old or exp > (tonumber(old.expirationTime) or 0) then
                        presentBd[e.key] = bd
                        present[e.key] = exp > 0 and (exp - now) or nil
                    end
                end
            end
        end
        for _, key in ipairs({ "mh", "oh" }) do
            local e = entries[key]
            if e then
                local has, rem, id = RC:HasWeaponEnchant(nil, e.slot)
                local nm = has and rem and rem > 0 and KnownWeaponEnchant(id)
                if nm then
                    present[key] = rem
                    presentBd[key] = { id = id, name = nm, expirationTime = now + rem }
                end
            end
        end

        -- what changed
        for key, rem in pairs(present) do
            local e = entries[key]
            local bd = presentBd[key]
            local st = state[key]
            local exp = now + rem
            local instance = bd.id or bd.name
            if st and (st.instance ~= instance or (st.exp and exp > st.exp + 2)) then
                st = nil      -- a new application (or a different stone)
            end
            if not st then
                st = { instance = instance, armed = false, spoke = false, new = true }
                -- the same application seen again after a blink (a loading
                -- screen, an entry rebuilt): it carries on where it was,
                -- so its line is never said a second time
                local m = VW.mem[key]
                if m and m.instance == instance and m.exp then
                    local d = m.exp - exp
                    if d < 0 then d = -d end
                    if d <= 2 then st.armed, st.spoke, st.new = m.armed, m.spoke, false end
                end
                state[key] = st
            end
            st.exp, st.seen, st.gone, st.reps = exp, now, nil, nil
            st.name = (e.weapon and bd.name) or e.name
            -- The bar's "show before expiry" (Zac: speak as soon as the
            -- threshold is hit). It used to be cut to the last tenth of a
            -- short buff, floor 5s, so a 15s Oil of Immolation spoke with
            -- 5s left. A buff no longer than the lead is inside it from the
            -- moment it goes on, so it is said as it goes on (Zac's pick).
            local lead = e.lead or 60
            local dur = tonumber(bd.duration)
            local shortBuff = st.new and dur and dur > 0 and dur <= lead
            st.lead = lead
            if rem > lead + 0.25 then
                if not st.armed then
                    DiagOnce(e, "arm", "watching %s: %ds left, says it at %ds", tostring(st.name), math_floor(rem), math_floor(lead))
                end
                st.armed = true
            elseif not st.spoke and not dead then
                -- first seen already inside the lead: right after a login,
                -- or an entry that only just appeared (a bar switched on,
                -- an item un-hidden) - said once, if it is a real consumable
                local fresh = boot or (now - ((VW.born and VW.born[key]) or 0)) < 10
                local bootOk = st.new and fresh and (e.weapon or (dur or 0) >= 60)
                if st.armed or bootOk or st.bootOwed or shortBuff then
                    if ItemCooldownBlocks(e.itemId, rem) then
                        DiagOnce(e, "cd", "not said, still on cooldown: %s", tostring(st.name))
                        st.spoke = true
                    else
                        st.spoke = Due(e, st)
                        -- held back by the zone: still owed while it is up
                        st.bootOwed = (not st.spoke) and (bootOk or shortBuff or st.bootOwed) or nil
                    end
                end
            end
            st.new = false
            st.last = rem
            local m = VW.mem[key]
            if not m then m = {}; VW.mem[key] = m end
            m.instance, m.exp, m.armed, m.spoke = instance, exp, st.armed, st.spoke
        end
        for key, st in pairs(state) do
            if present[key] == nil then
                local e = entries[key]
                if not st.gone then
                    st.gone = now
                    -- ran out = gone at its own end time. Gone with time
                    -- still on it is not an expiry, even inside the lead:
                    -- cancelled, dispelled, or pushed off by a rival you
                    -- just used - that used to start this item's repeats.
                    local ranOut = st.exp and (st.exp - now) <= 2.5
                    -- buffs drop on death (not an expiry); a weapon enchant
                    -- does not, so one that runs out while you are dead is
                    -- still owed its line
                    if (dead and not (e and e.weapon)) or not ranOut or not e then
                        DiagOnce(e, "gone", "%s gone with %ss left%s - not an expiry", tostring(st.name),
                            tostring(st.last and math_floor(st.last) or "?"), dead and " (dead)" or "")
                        state[key] = nil       -- removed early, or died: not an expiry
                    else
                        if not st.spoke and st.armed then
                            -- it ran out between looks (a loading screen), or
                            -- while you were dead: said now, or once you are up
                            if dead then
                                st.owed = true
                            elseif ItemCooldownBlocks(e.itemId, 0) then
                                st.spoke = true
                            elseif Due(e, st) then
                                st.spoke = true
                            else
                                st.owed = true
                            end
                        end
                        local n, every = RepeatSettings()
                        if st.owed then
                            st.reps, st.every = n, every
                            st.repAt = now
                        elseif st.spoke and n > 0 and ItemRepeatEnabled(e.itemId) then
                            st.reps, st.every = n, every
                            st.repAt = math_max(now, st.exp or now) + every
                        else
                            state[key] = nil
                        end
                    end
                elseif st.owed then
                    -- the line a death held back, once you are up
                    if not e or (now - st.gone) > 1800 or RivalUp(e) then
                        state[key] = nil
                    elseif not dead and (ItemCooldownBlocks(e.itemId, 0) or Due(e, st)) then
                        st.owed, st.spoke = nil, true
                        local every = st.every or 60
                        if (st.reps or 0) > 0 and ItemRepeatEnabled(e.itemId) then
                            st.repAt = now + every
                        else
                            state[key] = nil
                        end
                    end
                elseif st.reps then
                    if not e or not ChannelOn(e.channel) or not ItemTTSEnabled(e.itemId)
                        or not ItemRepeatEnabled(e.itemId) or (now - st.gone) > 1800 then
                        state[key] = nil
                    elseif dead then
                        -- a buff: a death resets it; a weapon: wait to be up
                        if not e.weapon then state[key] = nil end
                    elseif now >= st.repAt then
                        if RivalUp(e) then
                            state[key] = nil
                        elseif ItemCooldownBlocks(e.itemId, 0) then
                            st.repAt = now + 5
                        elseif Due(e, st) then
                            st.reps = st.reps - 1
                            st.repAt = now + (st.every or 60)
                            if st.reps <= 0 then state[key] = nil end
                        else
                            st.repAt = now + 5      -- not in this zone: try again shortly
                        end
                    end
                else
                    state[key] = nil
                end
            end
        end

        if #VW.due > 0 then
            local line = table.concat(VW.due, ", ")
            RC:DebugPrint("Voice watch: " .. line, "consumables")
            local okSpeak = RC:SpeakTTS(line, true, "consume")
            Diag("queued: %s%s", line, okSpeak and "" or " (voice off / not queued)")
        end
    end
    VW.Tick = Tick

    -- What the voice is warning about right now, for the centre-screen
    -- reminder to show at the same moment: every watched consumable that
    -- is still up, inside its warning lead, and that the voice speaks for
    -- (its bar's voice on, the item's TTS ticked, its bar shown here).
    -- Fills `out` with { key, itemId, name, text, left, weapon, slot }.
    function RC:VoiceWatchRunningOut(out)
        out = out or {}
        for i = #out, 1, -1 do out[i] = nil end
        local entries, state = VW.entries, VW.state
        if not (entries and state) then return out end
        local now = GetTime()
        for key, st in pairs(state) do
            local e = entries[key]
            if e and st.exp and not st.gone and st.lead then
                local left = st.exp - now
                if left > 0 and left <= st.lead
                   and ChannelOn(e.channel) and ItemTTSEnabled(e.itemId) and OwnerShows(e) then
                    local nm = st.name or e.name
                    out[#out + 1] = { key = key, itemId = e.itemId, name = nm, left = left,
                                      text = RC:ConsumableSpokenText(nm, e.itemId) or nm,
                                      weapon = e.weapon, slot = e.slot }
                end
            end
        end
        return out
    end

    -- The warning lead the voice uses for a buff (the bar's "show before
    -- expiry", narrowed for short buffs), once it has been seen; nil before.
    function RC:VoiceWatchLead(key)
        local st = VW.state and VW.state[key]
        return st and st.lead or nil
    end

    -- An error inside a ticker's callback can stop the ticker for good -
    -- and with it every expiry line until the next /reload, which reads
    -- exactly like "the voice works some sessions and not others". Each
    -- pass runs protected; an error is noted (debug "consumables" and the
    -- decision log) and the watch carries on with the next pass.
    local function SafeTick()
        local ok, err = pcall(Tick)
        if not ok then
            VW.errors = (VW.errors or 0) + 1
            if VW.errors <= 3 or VW.errors % 100 == 0 then
                RC:DebugPrint("Voice watch error: " .. tostring(err), "consumables")
                Diag("voice watch error #%d: %s", VW.errors, tostring(err))
            end
        end
    end

    function RC:StartConsumableVoiceWatch()
        if VW.ticker then return end
        VW.startedAt = GetTime()
        if RC.Profiler and RC.Profiler.TrackTicker then
            VW.ticker = RC.Profiler:TrackTicker("Consumables:VoiceWatch", VW_TICK, SafeTick)
        else
            VW.ticker = C_Timer.NewTicker(VW_TICK, SafeTick)
        end
    end

    function RC:InitConsumableTTSVoice()
        local saved = self.db and self.db.consumablesHelper and self.db.consumablesHelper.ttsVoiceId
        if saved then
            _ttsVoiceId = saved
            self:DebugPrint("TTS voice loaded from saved preference: id=" .. _ttsVoiceId, "consumables")
        else
            _ttsVoiceId = FindFemaleVoice()
            self:DebugPrint("TTS voice auto-detected female: id=" .. _ttsVoiceId, "consumables")
        end
    end
    _chs.SmoothSetSize = SmoothSetSize
    _chs.ShortenConsumableName = ShortenConsumableName
end

-- 3s: the TTS voice list is not populated until well after ADDON_LOADED,
-- and querying it early returns an empty set that never refreshes.
C_Timer.After(3, function()
    local RC = _G.Readycheck
    if RC and RC.InitConsumableTTSVoice then
        RC:InitConsumableTTSVoice()
    end
end)
