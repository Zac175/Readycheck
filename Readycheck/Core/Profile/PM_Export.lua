------------------------------------------------------------------------
-- Readycheck - Settings Export / Import
-- Serializes selected db keys to a portable string (RCS2 deflate-
-- compressed, falling back to legacy WRS1 plain base64) and parses them
-- back on import. Operates on self.db (the currently loaded character's
-- live settings), so import overwrites the settings of whichever
-- character is logged in when it runs.
-- Also home to RC:IdentifyImport / RC:ImportAny, which recognise ANY
-- string Readycheck exports and route it to the importer that owns it.
-- New persistable data must be added to RC.SETTINGS in PM_Registry.lua -
-- this file only consumes the EXPORTABLE_KEYS/EXPORT_CATEGORIES derived
-- from that registry, it does not declare keys itself.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end
RC._pms = RC._pms or {}
local _pms = RC._pms
    -- Derived from the settings registry (PM_Registry.lua). Previously a
    -- hand-maintained list that drifted out of step with EXPORT_CATEGORIES,
    -- leaving keys that were exportable but in no category - and so could
    -- never actually be selected, exported or synced.
    local EXPORTABLE_SETTINGS = RC.EXPORTABLE_KEYS or {}

    -- Kept for callers; the real work now lives in the registry audit, which
    -- checks both directions instead of only defaults-vs-exportable.
    function RC:AuditExportableSettings()
        if not self.defaults then return end
        if self.AuditSettingsRegistry then self:AuditSettingsRegistry(false) end
    end

    -- RC.EXPORT_CATEGORIES is derived in PM_Registry.lua from RC.SETTINGS.

    function RC:ExportSelectedSettings(selectedCategoryIds)
        if not self.db then return nil end

        local keysToExport = {}
        if RC.EXPORT_CATEGORIES then
            local selected = {}
            for _, id in ipairs(selectedCategoryIds) do selected[id] = true end
            for _, cat in ipairs(RC.EXPORT_CATEGORIES) do
                if selected[cat.id] then
                    for _, k in ipairs(cat.keys) do keysToExport[k] = true end
                end
            end
        end

        local exportData = {
            version = 1,
            addon = "Readycheck",
            type = "settings",
            timestamp = time(),
            characterName = UnitName("player"),
            realmName = GetRealmName(),
            data = {}
        }

        for _, key in ipairs(EXPORTABLE_SETTINGS) do
            if keysToExport[key] and self.db[key] ~= nil then
                -- Deep copy: a shallow reference here would let later edits to
                -- self.db mutate the snapshot before/while it's serialized.
                exportData.data[key] = self.DeepCopy(self.db[key])
            end
        end

        local serialized = self:SerializeTableForSettings(exportData)
        if not serialized then return nil end

        -- Compressed RCS2 format (LibDeflate): identical payload to the
        -- legacy plain-base64 WRS1 strings but ~15-25x smaller, so huge
        -- profiles no longer freeze/crash the client on paste/import.
        -- Falls back to WRS1 if the library is somehow unavailable.
        local LibDeflate = LibStub and LibStub:GetLibrary("LibDeflate", true)
        if LibDeflate then
            local compressed = LibDeflate:CompressDeflate(serialized, { level = 8 })
            local encoded = compressed and LibDeflate:EncodeForPrint(compressed)
            if encoded then
                return "RCS2:" .. encoded
            end
        end
        return "WRS1:" .. self:EncodeBase64ForSettings(serialized)
    end

    function RC:ImportAllSettings(importString)
        if importString then
            importString = importString:gsub("^%s+", ""):gsub("%s+$", "")
        end
        -- RCS2/WRS2: LibDeflate-compressed payload. WRS1: legacy plain
        -- base64 payload from before compression support was added.
        local decoded
        if importString and (importString:match("^RCS2:") or importString:match("^WRS2:")) then
            local LibDeflate = LibStub and LibStub:GetLibrary("LibDeflate", true)
            if not LibDeflate then
                self:Print(RCL["ERROR: Failed to decode import string"])
                return false
            end
            local raw = LibDeflate:DecodeForPrint(importString:sub(6):gsub("%s+", ""))
            decoded = raw and LibDeflate:DecompressDeflate(raw)
        elseif importString and importString:match("^WRS1:") then
            decoded = self:DecodeBase64ForSettings(importString:sub(6))
        else
            self:Print(RCL["ERROR: Invalid import string format"])
            return false
        end

        if not decoded then
            self:Print(RCL["ERROR: Failed to decode import string"])
            return false
        end

        local data = self:DeserializeTableForSettings(decoded)

        if not data then
            self:Print(RCL["ERROR: Failed to parse import data"])
            return false
        end

        if data.addon ~= "WarriorReminder" and data.addon ~= "Readycheck" then
            self:Print(RCL["ERROR: Import data is not from Readycheck"])
            return false
        end

        if data.type ~= "settings" then
            self:Print(RCL["ERROR: Import data is not a settings export"])
            return false
        end

        if not data.data then
            self:Print(RCL["ERROR: Import data is empty"])
            return false
        end

        local allowed = {}
        for _, k in ipairs(EXPORTABLE_SETTINGS) do allowed[k] = true end

        local imported = 0
        local skipped = 0
        for key, value in pairs(data.data) do
            if not allowed[key] then
                skipped = skipped + 1
                self:DebugPrint("Import: skipped non-exportable key '"
                    .. tostring(key) .. "'", "system")
            elseif self.db[key] ~= nil and type(value) ~= type(self.db[key]) then
                skipped = skipped + 1
                self:DebugPrint("Import: skipped key '" .. tostring(key)
                    .. "' (type mismatch: got " .. type(value)
                    .. ", expected " .. type(self.db[key]) .. ")", "system")
            else
                self.db[key] = self.DeepCopy(value)
                imported = imported + 1
            end
        end

        if imported == 0 then
            self:Print(RCL["ERROR: Import contained no valid settings"])
            return false
        end

        self:SaveConfigurationToProfile()

        local sourceInfo = ""
        if data.characterName and data.realmName then
            sourceInfo = " (from " .. data.characterName .. "-" .. data.realmName .. ")"
        end

        local skipInfo = skipped > 0 and (", " .. skipped .. " skipped") or ""
        self:Print(RCL["Imported "] .. imported .. RCL[" setting categories"] .. skipInfo .. sourceInfo)

        return true
    end

    function RC:SerializeTableForSettings(tbl, depth)
        depth = depth or 0
        if depth > 20 then
            return nil
        end

        local parts = {"{"}
        local first = true

        for k, v in pairs(tbl) do
            if not first then parts[#parts+1] = "," end
            first = false

            if type(k) == "string" then
                parts[#parts+1] = "[\"" .. k:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. "\"]="
            else
                parts[#parts+1] = "[" .. tostring(k) .. "]="
            end

            if type(v) == "table" then
                local sub = self:SerializeTableForSettings(v, depth + 1)
                if not sub then return nil end
                parts[#parts+1] = sub
            elseif type(v) == "string" then
                parts[#parts+1] = "\"" .. v:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. "\""
            elseif type(v) == "boolean" then
                parts[#parts+1] = v and "true" or "false"
            elseif type(v) == "number" then
                parts[#parts+1] = tostring(v)
            else
                parts[#parts+1] = "nil"
            end
        end

        parts[#parts+1] = "}"
        return table.concat(parts)
    end

    function RC:DeserializeTableForSettings(str)
        if not str or str == "" then return nil end

        local func, err = loadstring("return " .. str)
        if not func then
            self:DebugPrint("Deserialize error: " .. tostring(err), "profile")
            return nil
        end

        if setfenv then setfenv(func, {}) end

        -- Execute in protected mode
        local success, result = pcall(func)
        if not success then
            self:DebugPrint("Deserialize pcall error: " .. tostring(result), "profile")
            return nil
        end

        return result
    end

    function RC:EncodeBase64ForSettings(str)
        local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        local parts = {}

        for i = 1, #str, 3 do
            local b1, b2, b3 = str:byte(i, i+2)
            b2 = b2 or 0
            b3 = b3 or 0

            local n  = b1 * 65536 + b2 * 256 + b3
            local c1 = math.floor(n / 262144) + 1
            local c2 = math.floor((n % 262144) / 4096) + 1
            local c3 = math.floor((n % 4096) / 64) + 1
            local c4 = (n % 64) + 1

            parts[#parts+1] = b64chars:sub(c1, c1)
            parts[#parts+1] = b64chars:sub(c2, c2)
            parts[#parts+1] = (i + 1 <= #str) and b64chars:sub(c3, c3) or "="
            parts[#parts+1] = (i + 2 <= #str) and b64chars:sub(c4, c4) or "="
        end

        return table.concat(parts)
    end

    function RC:DecodeBase64ForSettings(str)
        local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        -- O(1) char lookup: the old per-character string:find made large
        -- legacy imports take tens of millions of scans in one frame.
        local lookup = {}
        for i = 1, 64 do lookup[b64chars:sub(i, i)] = i - 1 end
        local parts = {}

        str = str:gsub("%s", "")

        for i = 1, #str, 4 do
            local c1 = str:sub(i,   i)
            local c2 = str:sub(i+1, i+1)
            local c3 = str:sub(i+2, i+2)
            local c4 = str:sub(i+3, i+3)

            local n1 = lookup[c1]
            local n2 = lookup[c2]
            if not n1 or not n2 then return nil end

            if c3 == "" or c4 == "" then return nil end
            local n3 = lookup[c3]
            local n4 = lookup[c4]
            if c3 ~= "=" and not n3 then return nil end
            if c4 ~= "=" and not n4 then return nil end
            n3 = n3 or 0
            n4 = n4 or 0

            local n  = n1 * 262144 + n2 * 4096 + n3 * 64 + n4
            parts[#parts+1] = string.char(math.floor(n / 65536))
            if c3 ~= "=" then parts[#parts+1] = string.char(math.floor((n % 65536) / 256)) end
            if c4 ~= "=" then parts[#parts+1] = string.char(n % 256) end
        end

        return table.concat(parts)
    end

    --------------------------------------------------------------------
    -- ANY IMPORT STRING, ANYWHERE
    -- Every export Readycheck writes starts differently, so a pasted
    -- string says what it is. RC:IdentifyImport reads that and describes
    -- it - what it is, what it carries, what importing it will do - and
    -- RC:ImportAny hands it to the importer that owns it, whichever box
    -- it was pasted into.
    --
    --   RCS2: / WRS2: / WRS1:   settings          ImportAllSettings (here)
    --   WR1:                    raid profile      ImportRaidProfile
    --   WRN1 / WRN2 / WRN3      boss/trash notes  ImportBossNotes      (Readycheck_Features)
    --   WR_CR: or a bare table  custom reminder   ImportCustomReminder (Readycheck_Reminders)
    --   WRROUTE1                raid route        RaidRoute:ImportRouteString (Readycheck_Reminders)
    --
    -- The importers that live in a companion addon are looked up when
    -- they are called, never at load: a string for a companion that is
    -- switched off is still recognised, and says which addon it needs.
    -- A string ZacUI wrote is passed across to ZacUI when it is loaded.
    -- Nothing here changes what any importer does with a string.
    --------------------------------------------------------------------

    -- Above this a paste is recognised by how it starts and nothing is
    -- decoded to describe it: describing means decoding the whole string
    -- once more (roughly a tenth of a second per 60,000 characters of
    -- compressed settings), and that is not worth a visible hitch.
    local DESCRIBE_LIMIT = 150000

    -- Pasted text has usually been through a chat app, and what a chat
    -- app leaves around a string is peeled off here: blank lines, a
    -- byte-order mark, non-breaking and zero-width spaces, a code fence
    -- (with or without a language word after it), inline-code backticks,
    -- a quote marker on every line. Backticks at the END only go when one
    -- was found at the start - a note may end in a backtick of its own.
    local function CleanImportText(text)
        if type(text) ~= "string" then return "" end
        -- how many backticks came off the front: that many, and no more,
        -- come off the back
        local ticks, quoted = 0, 0
        local n
        -- From the end, byte by byte: a pattern ending in "$" is tried at
        -- every blank in the text, which on a long run of blanks in the
        -- middle of a paste takes seconds.
        local function Trim()
            local e = #text
            while e > 0 do
                local b = text:byte(e)
                if b == 32 or (b >= 9 and b <= 13) then
                    e = e - 1
                elseif b == 160 and e >= 2 and text:byte(e - 1) == 194 then
                    e = e - 2
                elseif b == 139 and e >= 3 and text:byte(e - 1) == 128 and text:byte(e - 2) == 226 then
                    e = e - 3
                else
                    break
                end
            end
            if e < #text then text = text:sub(1, e) end
        end
        local again = true
        while again do
            again = false
            text, n = text:gsub("^%s+", "")                        if n > 0 then again = true end
            text, n = text:gsub("^\239\187\191", "")               if n > 0 then again = true end
            text, n = text:gsub("^\194\160", "")                   if n > 0 then again = true end
            text, n = text:gsub("^\226\128\139", "")               if n > 0 then again = true end
            local _, marks = text:find("^>+")
            if marks then
                text, again = text:sub(marks + 1), true
                if quoted == 0 then quoted = marks end
            end
            -- a fence's language word is lower case; WRN3 and WRROUTE1,
            -- which also sit alone on a first line, are not
            text, n = text:gsub("^```%l*[ \t]*\r?\n", "")          if n > 0 then again, ticks = true, ticks + 3 end
            local _, last = text:find("^`+")
            if last then
                text, ticks, again = text:sub(last + 1), ticks + last, true
            end
        end
        Trim()
        if ticks > 0 then
            local e, took = #text, 0
            while took < ticks and e > 0 and text:byte(e) == 96 do e, took = e - 1, took + 1 end
            if took > 0 then
                text = text:sub(1, e)
                Trim()
            end
        end
        -- A quote block marks every line, not only the first. The marks come
        -- off only when every line that has anything on it carries one: a
        -- single ">" before the first line says nothing about the others,
        -- and a line of the string itself may begin with ">".
        if quoted > 0 and text:find("\n", 1, true) then
            local all = true
            for line in text:gmatch("\n([^\n]*)") do
                if line:find("%S") and not line:find("^[ \t]*>") then all = false break end
            end
            if all then
                text = text:gsub("\n[ \t]*" .. (">"):rep(math.min(quoted, 8)) .. "[ \t]?", "\n")
                Trim()
            end
        end
        return text
    end

    -- True when `str` is nothing but a table of plain values: no function,
    -- no call, no comment, no long string. Text that passes can be handed
    -- to loadstring to be READ - there is nothing in it that can run, loop
    -- or call - and it is the only kind this file ever loads to describe a
    -- paste. Quoted strings are stepped over by their own closing quote,
    -- so a custom reminder's code, which travels as a string, stays one.
    -- Returns true, or false and "cut" when a quoted string never closes
    -- (the paste was cut short - damage, not code).
    local function PureLiteral(str)
        local pos = 1
        while true do
            local s, _, ch = str:find("([\"'%(%[f%-])", pos)
            if not s then return true end
            if ch == '"' or ch == "'" then
                local p = s + 1
                while true do
                    local q = str:find("[\\" .. ch .. "]", p)
                    if not q then return false, "cut" end
                    if str:sub(q, q) == "\\" then p = q + 2 else pos = q + 1 break end
                end
            elseif ch == "(" then
                return false
            elseif ch == "[" then
                local nx = str:sub(s + 1, s + 1)
                if nx == "[" or nx == "=" then return false end
                pos = s + 1
            elseif ch == "-" then
                if str:sub(s + 1, s + 1) == "-" then return false end
                pos = s + 1
            else
                if str:find("^function", s) and not str:sub(s - 1, s - 1):find("[%w_]")
                   and not str:sub(s + 8, s + 8):find("[%w_]") then return false end
                pos = s + 1
            end
        end
    end

    -- Reads a table of plain values without printing anything when it is
    -- not one. Returns the table, or nil and "code" (there is something
    -- in it besides plain values - it was not loaded at all) or "damaged".
    local function QuietLoad(str)
        if type(str) ~= "string" or str == "" then return nil, "damaged" end
        local pure, why = PureLiteral(str)
        if not pure then
            -- a not-a-number the client itself wrote out ("-nan(ind)")
            -- is a broken export, not somebody's code
            if why == "cut" or str:find("nan(ind)", 1, true) then return nil, "damaged" end
            return nil, "code"
        end
        local fn = loadstring("return " .. str)
        if not fn then return nil, "damaged" end
        if setfenv then setfenv(fn, {}) end
        local ok, result = pcall(fn)
        if ok and type(result) == "table" then return result end
        return nil, "damaged"
    end

    local function CountKeys(t)
        local n = 0
        if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end
        return n
    end

    local function WhenExported(ts)
        ts = tonumber(ts)
        -- a real export's time; anything else never reaches date()
        if not ts or not (ts > 0 and ts < 4102444800) or not date then return nil end
        return date("%Y-%m-%d %H:%M", ts)
    end

    local function DetectImportKind(text)
        if text == "" then return "empty" end
        local head = text:sub(1, 12)
        if head:find("^RCS2:") or head:find("^WRS2:") or head:find("^WRS1:") then return "settings" end
        if head:find("^WR1:") then return "raidProfile" end
        if head:find("^WRN[123]") then return "notes" end
        if head:find("^WR_CR:") then return "reminder" end
        -- A route's header is found wherever it is, like its importer does.
        if text:sub(1, 400):find("WRROUTE1", 1, true) then return "route" end
        -- A custom reminder copied without its prefix is still a table
        -- with a mode in it; its importer has always taken those.
        if head:find("^{") and text:sub(-1) == "}"
           and text:sub(1, 70000):find("mode", 1, true) then
            return "reminder"
        end
        return nil
    end

    -- Strings that belong to ZacUI, for naming them when ZacUI is not
    -- there to do it itself.
    local ZACUI_STRINGS = {
        { "^ZacUI:%d+:",        RCL["a ZacUI profile"] },
        { "^ZacUILoadout:%d+:", RCL["a ZacUI bar loadout"] },
        { "^ZacUIBuffs:%d+:",   RCL["a ZacUI buff remover setup"] },
        { "^ZacUF1!",           RCL["a ZacUI unit frames profile"] },
        { "^!WA:%d+!",          RCL["a WeakAuras string"] },
    }

    local function CompanionProblem(self, addonName)
        if self.CompanionStatus and self:CompanionStatus(addonName) == "loading" then
            return RCL["Readycheck is still starting up - try again in a moment."]
        end
        return RCL["Needs the "] .. addonName .. RCL[" addon. Enable it in your AddOns list and /reload."]
    end

    local DAMAGED = RCL["The string is damaged or incomplete - copy it again, all of it."]
    local HASCODE = RCL["This string has code in it where only settings belong, so it was not opened."]

    -- Compressed settings are inflated to be described, and a small
    -- string can inflate to a very large one - so only modest ones are
    -- opened on paste, and a result past INFLATED_LIMIT is not read.
    local SETTINGS_DESCRIBE_LIMIT = 60000
    local INFLATED_LIMIT = 2000000

    -- A settings string as its importer decodes it (nil when it cannot be).
    local function DecodeSettings(self, text)
        if text:find("^WRS1:") then
            return self:DecodeBase64ForSettings(text:sub(6))
        end
        local LibDeflate = LibStub and LibStub:GetLibrary("LibDeflate", true)
        if not LibDeflate then return nil end
        local raw = LibDeflate:DecodeForPrint((text:sub(6):gsub("%s+", "")))
        return raw and LibDeflate:DecompressDeflate(raw) or nil
    end

    -- A route's data as its importer will load it. Returns a problem, or
    -- nil and the text (plus the same text with curly quotes mended, when
    -- that differs: the importer loads the text as it came and, if that
    -- gives nothing, mends the quotes and loads it again - so BOTH forms
    -- must be plain values, or the one that is not must not compile).
    local function RouteBodyProblem(text)
        text = text:gsub("\194\160", " ")
        local at = text:find("WRROUTE1", 1, true)
        if not at then return nil end
        local rest = text:sub(at + 8)
        local open = rest:find("{", 1, true)
        if not open then return nil end
        local body = rest:sub(open)
        local last = body:match(".*()}")
        if not last then return nil end
        local raw = body:sub(1, last):gsub("[\r\n]", "")
        local pure, why = PureLiteral(raw)
        if not pure and loadstring("return " .. raw) then return HASCODE end
        local straight = raw:gsub("\226\128[\156\157]", '"')
        straight = straight:gsub("\226\128[\152\153]", "'")
        if straight ~= raw then
            local pure2, why2 = PureLiteral(straight)
            if not pure2 then return (why2 == "cut") and DAMAGED or HASCODE end
            return nil, raw, straight
        end
        if not pure then return DAMAGED end
        return nil, raw
    end

    -- Last check before an importer that uses loadstring is called: the
    -- exact text it will load must be plain values. Describing a paste
    -- does this for strings it opens (info.scanned); this covers the ones
    -- too large to open on paste. Returns a problem, or nil.
    local function PayloadProblem(self, kind, text)
        local payload
        if kind == "settings" then
            payload = DecodeSettings(self, text)
        elseif kind == "raidProfile" then
            payload = self.DecodeBase64ForRaid and self:DecodeBase64ForRaid(text:sub(5))
        elseif kind == "reminder" then
            payload = text:match("^WR_CR:(.+)$") or text
        elseif kind == "route" then
            return (RouteBodyProblem(text))
        end
        if type(payload) ~= "string" or payload == "" then return nil end
        local pure, why = PureLiteral(payload)
        if pure then return nil end
        if why == "cut" or payload:find("nan(ind)", 1, true) then return DAMAGED end
        return HASCODE
    end

    local function DescribeSettings(self, text, info, deep)
        info.title  = RCL["Readycheck settings"]
        info.effect = RCL["Replaces this character's settings for the categories in the string, then reloads the UI."]
        info.reload = true
        info.ready  = true
        if not deep or #text > SETTINGS_DESCRIBE_LIMIT then
            info.lines[#info.lines + 1] = RCL["A large export - "] .. #text .. RCL[" characters."]
            return
        end
        if not text:find("^WRS1:") and not (LibStub and LibStub:GetLibrary("LibDeflate", true)) then return end
        local decoded = DecodeSettings(self, text)
        if decoded and #decoded > INFLATED_LIMIT then
            info.lines[#info.lines + 1] = RCL["A large export - "] .. #text .. RCL[" characters."]
            return
        end
        info.scanned = true
        local data, why = QuietLoad(decoded)
        if not data then
            info.ready, info.problem = false, (why == "code") and HASCODE or DAMAGED
            return
        end
        if (data.addon ~= "WarriorReminder" and data.addon ~= "Readycheck")
           or data.type ~= "settings" or type(data.data) ~= "table" then
            info.ready, info.problem = false, RCL["This is not a Readycheck settings export."]
            return
        end
        local from = data.characterName and data.realmName
            and (tostring(data.characterName) .. "-" .. tostring(data.realmName)) or nil
        local when = WhenExported(data.timestamp)
        if from or when then
            info.lines[#info.lines + 1] = (from and (RCL["From "] .. from) or RCL["Exported"])
                .. (when and (from and (RCL[", exported "] .. when) or (" " .. when)) or "")
        end
        -- Which categories it carries, by the names the export page uses.
        local labels, seen = {}, {}
        for _, cat in ipairs(RC.EXPORT_CATEGORIES or {}) do
            for _, k in ipairs(cat.keys) do
                if data.data[k] ~= nil and not seen[cat.id] then
                    seen[cat.id] = true
                    labels[#labels + 1] = cat.label
                end
            end
        end
        if #labels > 0 then
            local shown = {}
            for i = 1, math.min(#labels, 6) do shown[i] = labels[i] end
            info.lines[#info.lines + 1] = #labels .. (#labels == 1 and RCL[" category: "] or RCL[" categories: "])
                .. table.concat(shown, ", ")
                .. (#labels > 6 and (RCL[" and "] .. (#labels - 6) .. RCL[" more"]) or "")
        else
            info.ready, info.problem = false, RCL["The export holds no settings this version knows."]
        end
    end

    local function DescribeRaidProfile(self, text, info, deep)
        info.title     = RCL["Raid profile"]
        info.wantsName = true
        info.effect    = RCL["Adds it as a new profile and makes it the active one for that raid. Nothing you have is overwritten."]
        if not self.ImportRaidProfile then
            info.problem = RCL["Readycheck is still starting up - try again in a moment."]
            return
        end
        info.ready = true
        if not deep then
            info.lines[#info.lines + 1] = RCL["A large export - "] .. #text .. RCL[" characters."]
            return
        end
        local raw  = self.DecodeBase64ForRaid and self:DecodeBase64ForRaid(text:sub(5))
        info.scanned = true
        local data, why = QuietLoad(raw)
        if not data then
            info.ready, info.problem = false, (why == "code") and HASCODE or DAMAGED
            return
        end
        if (data.addon ~= "WarriorReminder" and data.addon ~= "Readycheck")
           or not data.raidName or type(data.data) ~= "table" then
            info.ready, info.problem = false, RCL["This is not a Readycheck raid profile."]
            return
        end
        info.raidName      = tostring(data.raidName)
        info.suggestedName = data.profileName and tostring(data.profileName) or nil
        info.title = RCL["Raid profile - "] .. info.raidName
            .. (info.suggestedName and (": '" .. info.suggestedName .. "'") or "")
        local parts = {}
        local bosses, trash = CountKeys(data.data.bosses), CountKeys(data.data.trash)
        local steps = data.data.route and data.data.route.steps
        parts[#parts + 1] = bosses .. (bosses == 1 and RCL[" boss"] or RCL[" bosses"])
        parts[#parts + 1] = trash .. RCL[" trash"]
        if type(steps) == "table" and #steps > 0 then
            parts[#parts + 1] = RCL["a route of "] .. #steps .. (#steps == 1 and RCL[" step"] or RCL[" steps"])
        end
        local when = WhenExported(data.timestamp)
        info.lines[#info.lines + 1] = table.concat(parts, ", ")
            .. (when and (RCL[" - exported "] .. when) or "")
        info.effect = RCL["Adds it as a new profile for "] .. info.raidName
            .. RCL[" and makes it the active one. Nothing you have is overwritten."]
    end

    local function DescribeNotes(self, text, info)
        info.title  = RCL["Boss and trash notes"]
        info.effect = RCL["Merges them into this character's notes. A note for the same boss and profile is replaced; everything else is kept."]
        local boss, trash = 0, 0
        local first = true
        for line in (text .. "\n"):gmatch("([^\n\r]*)\r?\n") do
            if first then
                first = false
            elseif line:find("\t", 1, true) then
                if line:find("^__") then trash = trash + 1 else boss = boss + 1 end
            end
        end
        info.lines[#info.lines + 1] = boss .. (boss == 1 and RCL[" boss note"] or RCL[" boss notes"])
            .. ", " .. trash .. (trash == 1 and RCL[" trash note"] or RCL[" trash notes"])
        if boss + trash == 0 then
            -- One long line where there should be one note per line: the
            -- line breaks did not survive wherever this was copied from.
            info.problem = RCL["No notes found in it. Each note is on its own line - if this was pasted through something that joins lines, export it again and paste it straight in."]
            return
        end
        if self.ImportBossNotes then
            info.ready = true
        else
            info.problem = CompanionProblem(self, "Readycheck_Features")
        end
    end

    local function DescribeReminder(self, text, info, deep)
        info.title  = RCL["Custom reminder"]
        info.effect = RCL["Adds it to Custom Reminders, switched off, with '(imported)' after its name."]
        if deep then
            info.scanned = true
            local tbl, why = QuietLoad((text:gsub("^WR_CR:", "")))
            if not tbl or not tbl.mode then
                info.problem = tbl and RCL["This is not a Readycheck custom reminder."]
                    or ((why == "code") and HASCODE or DAMAGED)
                return
            end
            if tbl.name then info.title = RCL["Custom reminder - '"] .. tostring(tbl.name) .. "'" end
            info.lines[#info.lines + 1] = RCL["Type: "] .. tostring(tbl.mode)
            -- Every reminder has a code field; only a "lua" one runs it.
            if tbl.mode == "lua" then
                info.lines[#info.lines + 1] = RCL["Runs custom Lua code - read it before you switch the reminder on."]
            end
        end
        if self.ImportCustomReminder then
            info.ready = true
        else
            info.problem = CompanionProblem(self, "Readycheck_Reminders")
        end
    end

    local function DescribeRoute(self, text, info, deep, opts)
        info.title = RCL["Raid route"]
        -- Same reading as the route importer: the raid is whatever sits
        -- between the header and the first "{".
        -- (and the same tidying: a non-breaking space is a space)
        text = text:gsub("\194\160", " ")
        local at   = text:find("WRROUTE1", 1, true)
        local rest = text:sub(at + 8)
        local open = rest:find("{", 1, true)
        if not open then
            info.problem = RCL["Only the route's header was pasted - copy the whole export, from WRROUTE1 to the last }."]
            return
        end
        local src = rest:sub(1, open - 1):gsub("\r", "\n"):gsub("[%s>`]+", " "):gsub("^ ", ""):gsub(" $", "")
        info.sourceRaid = src
        if src ~= "" then info.title = RCL["Raid route - "] .. src end
        -- Scanned whatever its size: the importer hands this to loadstring.
        local problem, raw, straight = RouteBodyProblem(text)
        if problem then
            info.problem = problem
            return
        end
        info.scanned = true
        if deep and raw and RC.MeshSync and RC.MeshSync.DeserializeTable then
            for _, lit in ipairs({ raw, straight }) do
                local ok, parsed = pcall(RC.MeshSync.DeserializeTable, RC.MeshSync, lit)
                if ok and type(parsed) == "table" and type(parsed.steps) == "table" then
                    info.lines[#info.lines + 1] = #parsed.steps
                        .. (#parsed.steps == 1 and RCL[" step"] or RCL[" steps"])
                    break
                end
            end
        end
        -- Where it goes: the route page it was opened from, else the raid
        -- named in the string - which has to be a raid we know, or a typo
        -- in a pasted header would invent a raid.
        local target = opts.raidName
        if not target or target == "" then
            local known = (RC.raidMobConfigs and RC.raidMobConfigs[src])
                or (self.db and self.db.raidProfiles and self.db.raidProfiles[src])
            if src ~= "" and known then target = src end
        end
        if not target then
            info.problem = (src == "" and RCL["The route does not say which raid it is for"]
                    or (RCL["'"] .. src .. RCL["' is not a raid this version knows"]))
                .. RCL[" - open Import Route on the route page of the raid you want it on and paste it there."]
            return
        end
        info.raidName = target
        if src ~= "" and src ~= target then
            info.lines[#info.lines + 1] = RCL["Exported from "] .. src .. RCL["; it goes onto "] .. target
                .. RCL[", the route page this was opened from."]
        end
        info.effect = RCL["Replaces the route in "] .. target .. RCL["'s active profile."]
        if RC.RaidRoute and RC.RaidRoute.ImportRouteString then
            info.ready = true
        else
            info.problem = CompanionProblem(self, "Readycheck_Reminders")
        end
    end

    -- What a pasted string is. Returns a table that is always safe to
    -- show:
    --   kind      "empty", "settings", "raidProfile", "notes", "reminder",
    --             "route", "zacui" (ZacUI will take it), "foreign" (it is
    --             somebody's, and they are not here) or "unknown"
    --   text      the string as the importers want it
    --   title     what it is, in a few words
    --   lines     what it carries, zero or more short lines
    --   effect    what importing it does
    --   ready     true when ImportAny can take it now; else problem says why
    --   reload    true when importing ends in a UI reload
    --   wantsName / suggestedName   a raid profile can be renamed on the way in
    --   raidName  the raid it will land on (raid profile, route)
    -- opts.raidName: the route page the import was opened from, if any.
    -- opts.own: do not ask ZacUI (set by ZacUI when it is the one asking).
    function RC:IdentifyImport(text, opts)
        opts = opts or {}
        local clean = CleanImportText(text)
        local info  = { text = clean, lines = {}, ready = false }
        local kind  = DetectImportKind(clean)
        info.kind = kind
        if kind == "empty" then return info end

        local deep = #clean <= DESCRIBE_LIMIT
        local describe
        if     kind == "settings"    then describe = DescribeSettings
        elseif kind == "raidProfile" then describe = DescribeRaidProfile
        elseif kind == "notes"       then describe = DescribeNotes
        elseif kind == "reminder"    then describe = DescribeReminder
        elseif kind == "route"       then describe = DescribeRoute
        end
        if describe then
            -- Describing reads untrusted text; whatever goes wrong in
            -- there, the paste box must keep working.
            local ok, err = pcall(describe, self, clean, info, deep, opts)
            if not ok then
                self:DebugPrint("IdentifyImport: describing a " .. tostring(kind)
                    .. " string failed: " .. tostring(err), "profile")
                info.ready, info.problem = false, DAMAGED
            end
            return info
        end

        if not opts.own then
            local zimp = _G.ZacUI and _G.ZacUI.Import
            if type(zimp) == "table" and zimp.Identify then
                local ok, zi = pcall(zimp.Identify, clean, { own = true })
                if ok and type(zi) == "table" and zi.kind
                   and zi.kind ~= "unknown" and zi.kind ~= "empty" then
                    info.kind    = "zacui"
                    info.foreign = zi
                    -- say who will take it, unless its own name already does
                    local title  = tostring(zi.title or "")
                    info.title   = title:find("ZacUI", 1, true) and title or ("ZacUI: " .. title)
                    info.lines   = type(zi.lines) == "table" and zi.lines or {}
                    info.effect  = zi.effect
                    info.ready   = zi.ready and true or false
                    info.problem = zi.problem
                    info.reload  = zi.reload and true or false
                    -- what Import does here is ZacUI's first action; if
                    -- that one saves under a name, the name is shown
                    local first = type(zi.actions) == "table" and zi.actions[1]
                    if type(first) == "table" and first.needsName then
                        info.wantsName     = true
                        info.suggestedName = zi.defaultName
                    end
                    return info
                end
            end
            for _, z in ipairs(ZACUI_STRINGS) do
                if clean:find(z[1]) then
                    info.kind    = "foreign"
                    info.title   = RCL["This is "] .. z[2]
                    info.problem = RCL["It belongs to ZacUI, which is not loaded on this character. Paste it into ZacUI's own import box."]
                    return info
                end
            end
        end

        info.kind    = "unknown"
        info.title   = RCL["Not recognised"]
        info.problem = RCL["This does not start like anything Readycheck exports. If it came from Readycheck, the beginning was probably cut off - copy it again, all of it."]
        return info
    end

    -- Imports whatever `text` is. opts:
    --   info      the result of IdentifyImport for this same text, to save
    --             describing it twice
    --   name      new name for a raid profile (optional)
    --   raidName  the route page the import was opened from (optional)
    --   activate  false to add a raid profile without switching to it
    -- Returns ok, message, result. message is nil when the importer has
    -- already said what it did in chat. result always has .kind, plus
    -- .reload when the UI must reload, .raidName/.profileName for a raid
    -- profile, .raidName for a route, .reminder for a custom reminder and
    -- .count for notes.
    local ImportUnrefreshed

    function RC:ImportAny(text, opts)
        local ok, msg, res = ImportUnrefreshed(self, text, opts)
        -- Whatever settings page is open was drawn from what was there
        -- before; some pages go on editing the tables they were drawn
        -- from. So after any import that does not end in a reload, the
        -- open page is drawn again - whoever asked for the import.
        if ok and type(res) == "table" and not res.reload and res.kind ~= "zacui"
           and self.RefreshAfterImport then
            local fine, err = pcall(self.RefreshAfterImport, self, res)
            if not fine then
                self:DebugPrint("ImportAny: page refresh failed: " .. tostring(err), "profile")
            end
        end
        return ok, msg, res
    end

    ImportUnrefreshed = function(self, text, opts)
        opts = opts or {}
        local info = opts.info
        if type(info) ~= "table" or info.text ~= CleanImportText(text) then
            info = self:IdentifyImport(text, opts)
        end
        local kind, clean = info.kind, info.text
        local res = { kind = kind }
        if kind == "empty" then return false, RCL["Nothing was pasted."], res end
        if not info.ready then
            return false, info.problem or RCL["That string cannot be imported."], res
        end
        -- Every importer below but the notes one hands text to loadstring.
        -- A string too large to have been opened when it was pasted is
        -- opened now, and refused if it is more than plain values.
        if not info.scanned then
            local problem = PayloadProblem(self, kind, clean)
            if problem then return false, problem, res end
        end

        if kind == "settings" then
            -- Prints its own outcome either way.
            if not self:ImportAllSettings(clean) then return false, nil, res end
            res.reload = true
            return true, nil, res

        elseif kind == "raidProfile" then
            local name = type(opts.name) == "string" and opts.name:gsub("^%s+", ""):gsub("%s+$", "") or nil
            if name == "" then name = nil end
            local ok, raid, prof = self:ImportRaidProfile(clean, name)
            if not (ok and raid and prof) then return false, nil, res end
            res.raidName, res.profileName = raid, prof
            if opts.activate ~= false and self.SetActiveRaidProfile then
                self:SetActiveRaidProfile(raid, prof)
                return true, "'" .. prof .. RCL["' is now the active profile for "] .. raid .. ".", res
            end
            return true, nil, res

        elseif kind == "notes" then
            local ok, n = self:ImportBossNotes(clean)
            if not ok then return false, tostring(n), res end
            res.count = n
            return true, RCL["Imported "] .. tostring(n) .. RCL[" note(s)."], res

        elseif kind == "reminder" then
            local r, err = self:ImportCustomReminder(clean)
            if not r then return false, tostring(err or RCL["unknown error"]), res end
            res.reminder = r
            return true, RCL["Added custom reminder '"] .. tostring(r.name)
                .. RCL["'. It is switched off until you turn it on."], res

        elseif kind == "route" then
            local ok, err = RC.RaidRoute:ImportRouteString(info.raidName, clean)
            if not ok then return false, tostring(err), res end
            self:SaveConfigurationToProfile()
            res.raidName = info.raidName
            return true, RCL["Route imported for "] .. info.raidName .. ".", res

        elseif kind == "zacui" then
            local zimp = _G.ZacUI and _G.ZacUI.Import
            if not (type(zimp) == "table" and zimp.Run) then
                return false, RCL["ZacUI is not loaded."], res
            end
            local okCall, ok, msg, zres = pcall(zimp.Run, clean, opts.action, { own = true, name = opts.name })
            if not okCall then return false, tostring(ok), res end
            if type(zres) == "table" then
                res.reload = zres.reload and true or nil
                res.zacui  = zres
            end
            return ok and true or false, msg, res
        end

        return false, RCL["That string cannot be imported."], res
    end

    C_Timer.After(2, function()
        if not ReadycheckDB or not ReadycheckDB.characters then
            return
        end

        local totalCleaned = 0
        for charKey, _ in pairs(ReadycheckDB.characters) do
            if RC.AutoCleanupProfile then
                local cleaned = RC:AutoCleanupProfile(charKey)
                totalCleaned = totalCleaned + cleaned
            end
        end

        if totalCleaned > 0 then
            RC:DebugPrint("Auto-cleanup complete: removed " .. totalCleaned .. " dead fields from all profiles", "profile")
        end

        if RC.AuditExportableSettings then RC:AuditExportableSettings() end
    end)

    RC:DebugPrint("Enhanced profile manager loaded with complete execute settings support (UI filters now persist)", "profile")
