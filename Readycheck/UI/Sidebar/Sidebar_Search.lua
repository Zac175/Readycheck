------------------------------------------------------------------------
-- Readycheck - Sidebar Settings Search
-- The /rc window's search: an index of every setting on every page, the
-- ranking, and the jump that opens a result's page (on the right tab),
-- scrolls the setting into view and flashes it. Sidebar_SearchBox draws
-- the results in a dropdown under the search box.
--
-- MATCHING (2026-11-07): case-insensitive, every word of the query
-- somewhere in the title, the description, the tooltip or the breadcrumb;
-- a word may sit at the start (best), at a word start, inside a word, as
-- letters in order ("castbar" finds "Cast Bar") or with one letter wrong.
-- Results are ranked by that, then a setting before its section before
-- the page. The /rc commands are results too (kind "command"); a page or
-- command of a feature this game version does not run is never listed.
--
-- WHY AN INDEX. The sidebar search used to match page names and the
-- hand-kept alias lists only, so most checkboxes and sliders could not be
-- found by their own label. Pages are code, not data, so the only full
-- list of what a page holds is the page itself: each one is BUILT ONCE,
-- unseen, the first time the search box is used, and its labels are read
-- back off the frames it made - text, card, tab, and how far down the
-- page it sits.
--
-- HOW A PAGE IS BUILT UNSEEN. Page functions render into
-- compatFrame.scrollChild and drive the scrollbar through the window's
-- contentFrame. For the length of one build both are pointed at a hidden
-- scratch pair, then put straight back, so nothing on screen is touched
-- and a page's own ClearSidebarContent / UpdateSidebarScrollbar land on
-- the scratch copy. Tabbed pages are built once per tab through the same
-- EVERY TAB IS FOUND BY ITSELF: while a page builds unseen, the tab rows
-- it draws are recorded, and each tab is clicked in turn (rows that only
-- appear under a tab too), so a setting added to any tab of any page is
-- in the index the next time - nothing to keep up to date by hand. Each
-- entry remembers the tabs it was found under; a jump opens the page,
-- clicks those tabs, scrolls to the setting and flashes it. Every "...Tab"
-- field the builds touch is restored afterwards, so a page reopens on the
-- tab you left it on. The hand-kept tab aliases (RC.SUBPANEL_ALIASES)
-- stay as extra keywords. Tooltips are read too: a control's tooltip text
-- is captured once from its own OnEnter while the page is unseen, so a
-- word that only lives in a tooltip still finds the control. One page
-- (with its tabs) per frame.
--
-- Pages with live data or side effects (world buff board, profiler,
-- changelog, remote config, raid boss pages) are not built; they are
-- still found by name and aliases, and a page you open refreshes its own
-- entries either way.
------------------------------------------------------------------------
local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local math_max, math_min, math_floor = math.max, math.min, math.floor
local table_insert, table_sort, table_concat = table.insert, table.sort, table.concat
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local RC = _G.Readycheck
if not (RC and RC.UI) then return end

local S = {}
RC.SidebarSearch = S

local SKIP = {
    world_buffs = true, profiler = true, changelog = true, remote_raid_cfg = true,
}

local index = {}      -- [itemId] = { entry, ... }
local done = {}       -- [itemId] = true once indexed
local running = false
local scratchChild, scratchScroll

-- (searchMode: results used to take the content pane; they drop under
-- the box now, so this stays false - Sidebar_Window and the custom
-- sections still ask)
S.searchMode = false
S.query = ""
S.results = {}
S.hits = {}

-- ============================================================
-- TEXT
-- ============================================================
local function Clean(text)
    if type(text) ~= "string" then return "" end
    text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
    text = text:gsub("|r", "")
    text = text:gsub("|T.-|t", "")
    text = text:gsub("|A.-|a", "")
    text = text:gsub("[\r\n]+", " ")
    text = text:gsub("%s+", " ")
    text = text:gsub("^ ", "")
    text = text:gsub(" $", "")
    return text
end
S.Clean = Clean

local function Tokens(text)
    local out = {}
    for w in (text or ""):lower():gmatch("%S+") do out[#out + 1] = w end
    return out
end
S.Tokens = Tokens

-- Every word somewhere in hay, any order.
function S.MatchAll(hay, tokens)
    if not hay or #tokens == 0 then return false end
    for _, w in ipairs(tokens) do
        if not hay:find(w, 1, true) then return false end
    end
    return true
end

-- Slider readouts, percentages and one-letter marks are a widget's state,
-- not a label anyone searches for.
local function Meaningful(t)
    if #t < 2 then return false end
    if t:match("^[%d%.%%%s%-%+x:/,]+$") then return false end
    return true
end

-- ============================================================
-- MENU
-- ============================================================
local function EachItem(fn)
    for _, cat in ipairs(RC.MenuStructure or {}) do
        if cat.panel then fn(cat, nil) end
        for _, child in ipairs(cat.children or {}) do fn(child, cat) end
    end
end

local function FindItem(id)
    local found, parent
    EachItem(function(item, cat)
        if not found and item.id == id then found, parent = item, cat end
    end)
    return found, parent
end
S.FindItem = FindItem

-- The sidebar's own visibility rules, for pages the user can open.
function S.IsVisible(item)
    if not item then return false end
    -- not on this game version: nothing on the page to find (Core_Flavor)
    if RC.FeatureOffForPage and RC:FeatureOffForPage(item) then return false end
    if item.warriorOnly and not RC.isWarrior then
        local nw = (RC.db and RC.db.nonWarriorEnabled) or {}
        if nw[item.id] ~= true then return false end
    end
    if item.sidebarVisibleKey and RC.db and RC.db.sidebarNav
            and RC.db.sidebarNav[item.sidebarVisibleKey] == false then
        return false
    end
    if item.enabledKey and RC.db then
        local tbl = RC.db[item.enabledKey[1]]
        if not (tbl and tbl[item.enabledKey[2]]) then return false end
    end
    return true
end

-- Group overview pages (a category's panel) show live on/off states and
-- only repeat their pages' names, so they are found by name and aliases.
local function Indexable(item)
    return item.panel and not item.raidKey and not item.category and not SKIP[item.id]
        and type(RC[item.panel]) == "function" and S.IsVisible(item)
end

local function AliasesFor(itemId)
    local out = {}
    for i, sub in ipairs(RC.SUBPANEL_ALIASES or {}) do
        if sub.parentId == itemId and type(sub.setTab) == "function" then
            out[#out + 1] = { index = i, sub = sub }
        end
    end
    return out
end

-- ============================================================
-- READING A BUILT PAGE
-- ============================================================
local function VFrac(point)
    if not point then return 0 end
    if point:find("TOP") then return 0 end
    if point:find("BOTTOM") then return 1 end
    return 0.5
end

local function Height(r)
    local ok, h = pcall(r.GetHeight, r)
    return (ok and type(h) == "number") and h or 0
end

-- Distance from the top of `stop` down to the top of `region`, from
-- anchors alone (nothing here is drawn, so GetTop has no answer).
local function OffsetY(region, stop, depth)
    depth = depth or 0
    if region == stop or depth > 12 or not region then return 0 end
    local n = region.GetNumPoints and region:GetNumPoints() or 0
    local parent = region.GetParent and region:GetParent()
    if n == 0 then
        if parent and parent ~= region then return OffsetY(parent, stop, depth + 1) end
        return 0
    end
    local point, rel, relPoint, _, y = region:GetPoint(1)
    rel = rel or parent
    if not rel then return y or 0 end
    local top = (y or 0) - VFrac(relPoint) * Height(rel) + VFrac(point) * Height(region)
    return OffsetY(rel, stop, depth + 1) + top
end

local function Shown(f)
    local ok, v = pcall(f.IsShown, f)
    return not ok or v
end

-- The tooltip a control shows, read once off its own OnEnter with
-- GameTooltip's writers swapped for a recorder (the page is unseen, the
-- tooltip never shows). nil when it has none.
local TIP_WRITERS = { "SetText", "AddLine", "AddDoubleLine" }
local TIP_QUIET = { "SetOwner", "Show", "Hide", "ClearLines", "SetMinimumWidth", "SetPoint", "ClearAllPoints",
    "SetHyperlink", "SetSpellByID", "SetItemByID", "AddTexture", "SetPadding", "SetAnchorType", "SetInventoryItem",
    "SetBagItem", "SetUnit", "SetUnitBuff", "SetUnitDebuff", "SetAction" }
local function CaptureTip(frame)
    local GT = _G.GameTooltip
    if not (GT and frame.GetScript) then return nil end
    local okE, onEnter = pcall(frame.GetScript, frame, "OnEnter")
    if not okE or type(onEnter) ~= "function" then return nil end
    local lines = {}
    local function Add(t) t = Clean(t) if Meaningful(t) then lines[#lines + 1] = t end end
    local saved = {}
    local function Swap(name, fn) saved[name] = rawget(GT, name) or false GT[name] = fn end
    Swap("SetText", function(_, t) Add(t) end)
    Swap("AddLine", function(_, t) Add(t) end)
    Swap("AddDoubleLine", function(_, a, b) Add(a) Add(b) end)
    for _, n in ipairs(TIP_QUIET) do Swap(n, function() end) end
    pcall(onEnter, frame)
    local okL, onLeave = pcall(frame.GetScript, frame, "OnLeave")
    if okL and type(onLeave) == "function" then pcall(onLeave, frame) end
    for name, v in pairs(saved) do
        if v == false then GT[name] = nil else GT[name] = v end
    end
    if #lines == 0 then return nil end
    return table_concat(lines, " ")
end
S.CaptureTip = CaptureTip

local function Collect(container, out, owner, depth)
    -- (customization sections sit three frames deeper than a card's own rows)
    if depth > 10 then return end
    -- a control's tooltip lands on it
    local tip = (container.IsObjectType and (container:IsObjectType("Button") or container:IsObjectType("CheckButton")
        or container:IsObjectType("Slider"))) and CaptureTip(container) or nil
    -- a value picker (a dropdown of choices) names every choice and its tooltip
    local choices = rawget(container, "_rcSearchTip")
    if not tip and type(choices) == "function" then
        local okC, t = pcall(choices)
        t = okC and Clean(t) or nil
        if Meaningful(t) then tip = t end
    end
    if tip then out[#out + 1] = { tipFor = container, text = tip, owner = owner or container } end
    for _, r in ipairs({ container:GetRegions() }) do
        -- (a card's title is its own entry; a customization group's label
        -- - "Count position", "Timer" - is a row like any other)
        if r.IsObjectType and r:IsObjectType("FontString")
            and (r ~= container.title or rawget(container, "_rcSearchTitle")) then
            -- a help line shows one line; its whole note is what is searched
            local t = Clean((rawget(container, "_rcHelpFS") == r and rawget(container, "_rcHelpText")) or r:GetText())
            if Meaningful(t) and Shown(r) then
                out[#out + 1] = { fs = r, text = t, owner = owner }
            end
        end
    end
    for _, c in ipairs({ container:GetChildren() }) do
        if Shown(c) and not (c.IsObjectType and c:IsObjectType("EditBox")) then
            Collect(c, out, owner or c, depth + 1)
        end
    end
end

-- Entries for everything on a built page. `alias` is the tab hook the
-- page was built through (nil for its default state).
-- path: the tabs selected while the page was read, in the order their
-- rows were drawn ({ sig =, key =, label =, many = }).
local function PathKey(path)
    if not path then return "" end
    local t = {}
    for _, st in ipairs(path) do t[#t + 1] = st.sig .. "=" .. tostring(st.key) end
    -- (the rows a page draws can come in another order per tab)
    table_sort(t)
    return table_concat(t, ";")
end
S.PathKey = PathKey

local function Scan(parent, item, alias, path)
    local entries = {}
    for _, box in ipairs({ parent:GetChildren() }) do
        -- The page header (it has a title but is not a card) only repeats
        -- the page name, which is matched separately.
        local isHeader = box.title and not box.titleText
        if Shown(box) and not isHeader then
            local boxY = OffsetY(box, parent)
            local card = type(box.titleText) == "string" and Clean(box.titleText) or nil
            if card == "" then card = nil end
            if card then
                entries[#entries + 1] = { kind = "card", label = card, card = card, y = boxY }
            end
            local found = {}
            Collect(box, found, nil, 0)
            for _, f in ipairs(found) do
                f.y = boxY + OffsetY(f.fs or f.tipFor, box)
                -- inside a customization section (shut until opened): the
                -- jump opens it
                local p, d = f.fs or f.tipFor, 0
                while p and p ~= box and d < 30 do
                    local k = rawget(p, "_rcFoldKey")
                    if k then f.fold = k break end
                    p = p.GetParent and p:GetParent() or nil
                    d = d + 1
                end
            end
            table_sort(found, function(a, b) return a.y > b.y end)
            -- a control's own label (the checkbox's caption, the button's
            -- text) names its tooltip
            local function OwnLabel(ctrl)
                for _, k in ipairs({ "Text", "text", "label" }) do
                    local fs = rawget(ctrl, k)
                    if type(fs) == "table" and type(fs.GetText) == "function" then
                        local okT, t = pcall(fs.GetText, fs)
                        if okT and type(t) == "string" then return Clean(t) end
                    end
                end
                return nil
            end
            local lastLabel
            for _, f in ipairs(found) do
                if f.tipFor then
                    local own = OwnLabel(f.tipFor)
                    if own == "" or (own and not Meaningful(own)) then own = nil end
                    entries[#entries + 1] = { kind = "tip", text = f.text,
                        label = own or lastLabel or card or f.text, card = card, y = f.y, fold = f.fold }
                elseif #f.text > 70 then
                    -- A description lands on the setting it explains.
                    entries[#entries + 1] = { kind = "desc", text = f.text,
                        label = lastLabel or card or f.text, card = card, y = f.y, fold = f.fold }
                else
                    entries[#entries + 1] = { kind = "row", label = f.text, card = card, y = f.y, fold = f.fold }
                    lastLabel = f.text
                end
            end
        end
    end
    for _, e in ipairs(entries) do
        e.item = item.id
        if alias then
            e.alias = alias.index
            e.tabLabel = alias.sub.tabLabel
        end
        if path and #path > 0 then
            e.tabPath = path
            local labels = {}
            for _, st in ipairs(path) do
                if st.many and st.label then labels[#labels + 1] = st.label end
            end
            if #labels > 0 then e.tabLabel = table_concat(labels, "  >  ") end
        end
        e.tabKey = PathKey(path)
        e.hay = ((e.label or "") .. " " .. (e.text or "")):lower()
        e.key = (e.kind or "") .. "\1" .. (e.label or "") .. "\1" .. (e.card or "")
            .. "\1" .. (e.text or "") .. "\1" .. e.tabKey
    end
    return entries
end

-- ============================================================
-- BUILDING A PAGE UNSEEN
-- ============================================================
local function EnsureScratch(compat)
    if scratchChild then return end
    scratchScroll = CreateFrame("ScrollFrame", nil, UIParent)
    scratchScroll:Hide()
    scratchScroll:SetSize(600, 600)
    scratchChild = CreateFrame("Frame", nil, scratchScroll)
    scratchScroll:SetScrollChild(scratchChild)
    local real = compat.scrollChild
    scratchChild:SetSize((real and real:GetWidth() and real:GetWidth() > 200) and real:GetWidth() or 560, 1500)
    local bar = CreateFrame("Slider", nil, scratchScroll)
    bar:SetOrientation("VERTICAL")
    bar:SetMinMaxValues(0, 0)
    bar:SetValue(0)
    scratchScroll.scrollBar = bar
end

local function IsTabKey(k)
    return type(k) == "string" and k:find("[Tt]ab") ~= nil
end

-- Every "...Tab" field on the objects a setTab hook writes to, so the
-- index can put back the tab the user actually left a page on.
local function SnapshotTabs(objs)
    local snap = {}
    for i, o in ipairs(objs) do
        local s = {}
        for k, v in pairs(o) do
            if IsTabKey(k) and type(v) ~= "function" and type(v) ~= "table" then s[k] = v end
        end
        snap[i] = s
    end
    return snap
end

local function RestoreTabs(objs, snap)
    for i, o in ipairs(objs) do
        local s = snap[i]
        local changed = {}
        for k, v in pairs(o) do
            if IsTabKey(k) and type(v) ~= "function" and type(v) ~= "table" and s[k] ~= v then
                changed[#changed + 1] = k
            end
        end
        for _, k in ipairs(changed) do o[k] = s[k] end
        for k, v in pairs(s) do
            if o[k] ~= v then o[k] = v end
        end
    end
end

local SWAP_COMPAT = { "scrollChild", "contentFrame", "elements", "layoutRows",
    "currentRow", "rowHeight", "currentBackButton" }
local SWAP_OUTER = { "contentFrame", "contentScrollChild", "pendingScrollRestore",
    "suppressScrollbarUpdate", "scrollbarUpdateTimer", "scrollbarUpdateTimer2" }

local function Merge(base, extra)
    local seen = {}
    for _, e in ipairs(base) do seen[e.key] = true end
    for _, e in ipairs(extra) do
        if not seen[e.key] then
            seen[e.key] = true
            base[#base + 1] = e
        end
    end
    return base
end

local function DryRun(item, alias)
    local outer = RC.sidebarConfigFrame
    local compat = outer and outer.compatFrame
    local fn = RC[item.panel]
    if not compat or type(fn) ~= "function" then return nil end
    EnsureScratch(compat)

    local savedC, savedO = {}, {}
    for _, k in ipairs(SWAP_COMPAT) do savedC[k] = compat[k] end
    for _, k in ipairs(SWAP_OUTER) do savedO[k] = outer[k] end
    local savedLast = RC._lastPageFrame
    local tabObjs = { RC, compat, outer }
    local tabs = SnapshotTabs(tabObjs)

    compat.scrollChild, compat.contentFrame = scratchChild, scratchScroll
    compat.elements, compat.layoutRows = {}, {}
    compat.currentRow, compat.rowHeight, compat.currentBackButton = 0, 0, nil
    outer.contentFrame, outer.contentScrollChild = scratchScroll, scratchChild
    outer.scrollbarUpdateTimer, outer.scrollbarUpdateTimer2 = nil, nil

    -- the tab rows each build draws on the scratch page
    local groups = {}
    local rawTabs = RC.UI.CreateTabGroup
    RC.UI.CreateTabGroup = function(selfUI, parentF, opts)
        local g, y = rawTabs(selfUI, parentF, opts)
        -- (opts.searchWalk = false: a row whose click changes more than
        -- the page shown - a saved choice - is left as it is)
        if g and parentF == scratchChild and type(opts) == "table" and type(opts.tabs) == "table" and opts.searchWalk ~= false then
            local keys, labels = {}, {}
            for i, td in ipairs(opts.tabs) do keys[i] = td.key labels[td.key] = Clean(td.label) end
            groups[#groups + 1] = { keys = keys, labels = labels, selected = opts.selected,
                onClick = opts.onClick, sig = table_concat(keys, ","), group = g }
        end
        return g, y
    end
    local function PathNow()
        local p = {}
        for _, g in ipairs(groups) do
            local sel = (type(g.group) == "table" and g.group.selected) or g.selected
            p[#p + 1] = { sig = g.sig, key = sel, label = g.labels[sel], many = #g.keys > 1 }
        end
        return p
    end
    local entries
    local function Read()
        local sok, res = pcall(Scan, scratchChild, item, alias, (not alias) and PathNow() or nil)
        if sok and res then entries = Merge(entries or {}, res)
        elseif not sok then RC:DebugPrint("Search index could not read " .. tostring(item.id) .. ": " .. tostring(res), "config") end
    end
    -- every tab of every row, rows under a tab too (three deep at most)
    local function Visit(depth, known)
        if depth > 3 then return end
        local snap = {}
        for i, g in ipairs(groups) do snap[i] = g end
        local inner = {}
        for k in pairs(known) do inner[k] = true end
        for _, g in ipairs(snap) do inner[g.sig] = true end
        for gi = #snap, 1, -1 do
            local g = snap[gi]
            if not known[g.sig] and type(g.onClick) == "function" then
                for _, k in ipairs(g.keys) do
                    if k ~= g.selected then
                        for i = #groups, 1, -1 do groups[i] = nil end
                        if pcall(g.onClick, k) then
                            -- a row that shows and hides its tabs in place
                            -- (no rebuild) draws no new rows: it is still the
                            -- one on screen, now on k
                            if #groups == 0 then
                                for i, gg in ipairs(snap) do groups[i] = gg end
                                if type(g.group) == "table" and g.group.selected ~= k then g.group.selected = k end
                                g.selected = k
                            end
                            Read()
                            Visit(depth + 1, inner)
                        end
                    end
                end
            end
        end
    end
    -- (customization sections build open while a page is read unseen)
    S.inDryRun, S.dryItem = true, item.id
    if not alias or pcall(alias.sub.setTab, outer) then
        local ok, err = pcall(fn, RC, compat)
        if ok then
            Read()
            if not alias then Visit(1, {}) end
        else
            RC:DebugPrint("Search index skipped " .. tostring(item.id) .. ": " .. tostring(err), "config")
        end
    end
    RC.UI.CreateTabGroup = rawTabs
    S.inDryRun, S.dryItem = false, nil

    -- Throw the scratch build away and put the real window back.
    if RC.UI.ReleaseCustomBlocks then RC.UI:ReleaseCustomBlocks(scratchChild) end
    for _, c in ipairs({ scratchChild:GetChildren() }) do
        c:Hide()
        c:ClearAllPoints()
        c:SetParent(nil)
        if RC.UI.DiscardTree then RC.UI:DiscardTree(c) end
    end
    for _, r in ipairs({ scratchChild:GetRegions() }) do r:Hide() end
    for _, k in ipairs(SWAP_COMPAT) do compat[k] = savedC[k] end
    -- A timer the page started points at the scratch pair; cancel it
    -- rather than let it hold the real slot.
    for _, k in ipairs({ "scrollbarUpdateTimer", "scrollbarUpdateTimer2" }) do
        local t = outer[k]
        if type(t) == "table" and t ~= savedO[k] and type(t.Cancel) == "function" then t:Cancel() end
    end
    for _, k in ipairs(SWAP_OUTER) do outer[k] = savedO[k] end
    RC._lastPageFrame = savedLast
    RestoreTabs(tabObjs, tabs)
    return entries
end

function S.IsIndexing() return running end

-- ============================================================
-- THE INDEX IS KEPT BETWEEN SESSIONS (2026-11-10)
-- Zac: "typing in the search box omega lags my game". Reading every page
-- unseen is the expensive part (each one is a full page build), and it
-- ran again on the first search of every session, one page a frame, the
-- moment the box was clicked - right under the typing. Now:
--   * what was read is saved account-wide (ReadycheckDB.searchIndex) with
--     a stamp of what it was read on: the version, the game version,
--     the language and which Readycheck parts are loaded. With the same
--     stamp the next session loads it and builds nothing; a new version
--     (or another part loaded) reads again, once.
--   * a page you open is re-read from the real page as before
--     (S.RefreshFromPage) and the saved copy follows.
--   * when pages do have to be read, the reading waits while keys are
--     arriving (TYPE_PAUSE after the last one), so typing stays smooth
--     and the results fill in a moment later.
-- Not a setting: never exported, and safe to delete (it is rebuilt).
-- ============================================================
local CACHE_FORMAT = 1
local TYPE_PAUSE = 0.4
local lastKey = -100
local cacheLoaded = false
local GetTime = GetTime

function S.NoteKey() lastKey = GetTime and GetTime() or 0 end

local function CacheSig()
    -- (not the class: one saved index serves every character on the
    -- account; a page only a Warrior has is read and added the first time
    -- a Warrior searches, and is simply not loaded for the others)
    local parts = { "f" .. CACHE_FORMAT, tostring(RC.version or "?"),
        tostring(RC.Flavor and RC:Flavor() or "?"),
        tostring(GetLocale and GetLocale() or "?") }
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    for _, a in ipairs({ "Readycheck_Features", "Readycheck_Reminders", "Readycheck_Consumables", "Readycheck_Gear",
                         "Readycheck_WorldTools", "Readycheck_Extras" }) do
        local okL, on = pcall(isLoaded or function() return false end, a)
        parts[#parts + 1] = (okL and on) and "1" or "0"
    end
    return table_concat(parts, "|")
end

-- A page as it is saved: its entries without what can be worked out
-- again (hay, key, the page id, the tab label a tab path gives), and its
-- tab paths once each (every entry on a tab carried its own copy).
local function Slim(id, list)
    local paths, out = {}, {}
    for i, e in ipairs(list) do
        local c = {}
        for k, v in pairs(e) do
            if k ~= "hay" and k ~= "key" and k ~= "item" and k ~= "tabPath" then c[k] = v end
        end
        if e.tabPath then
            paths[e.tabKey or ""] = e.tabPath
            c.tabLabel = nil
        end
        out[i] = c
    end
    return { p = paths, e = out }
end
local function Fatten(id, saved)
    local list = {}
    local paths = type(saved.p) == "table" and saved.p or {}
    for i, c in ipairs(saved.e or {}) do
        local e = {}
        for k, v in pairs(c) do e[k] = v end
        e.item = id
        local path = paths[e.tabKey or ""]
        if path then
            e.tabPath = path
            local labels = {}
            for _, st in ipairs(path) do
                if st.many and st.label then labels[#labels + 1] = st.label end
            end
            if #labels > 0 then e.tabLabel = table_concat(labels, "  >  ") end
        end
        e.hay = ((e.label or "") .. " " .. (e.text or "")):lower()
        e.key = (e.kind or "") .. "\1" .. (e.label or "") .. "\1" .. (e.card or "")
            .. "\1" .. (e.text or "") .. "\1" .. (e.tabKey or "")
        list[i] = e
    end
    return list
end

local function Cache(create)
    if type(ReadycheckDB) ~= "table" then return nil end
    local c = ReadycheckDB.searchIndex
    local sig = CacheSig()
    if type(c) ~= "table" or c.sig ~= sig or type(c.pages) ~= "table" then
        if not create then return nil end
        c = { sig = sig, pages = {} }
        ReadycheckDB.searchIndex = c
    end
    return c
end

-- once per session: the saved pages for this stamp come in
local function LoadCache()
    if cacheLoaded then return end
    cacheLoaded = true
    local c = Cache(false)
    if not c then return end
    EachItem(function(item)
        local saved = c.pages[item.id]
        if type(saved) == "table" and not done[item.id] and Indexable(item) then
            local okF, list = pcall(Fatten, item.id, saved)
            if okF and type(list) == "table" then
                index[item.id] = list
                done[item.id] = true
            end
        end
    end)
end
local function SavePage(id)
    if not done[id] then return end
    local c = Cache(true)
    -- (a page with nothing to find is saved empty, so it is not read again)
    if c then c.pages[id] = Slim(id, index[id] or {}) end
end
function S.ForgetSaved()
    if type(ReadycheckDB) == "table" then ReadycheckDB.searchIndex = nil end
end
function S.SavedSig() local c = Cache(false) return c and c.sig or nil end

-- Builds the index in the background, one page (or tab) per frame.
-- onDone runs once everything is in.
function S.EnsureIndex(onDone)
    if running or not RC.sidebarConfigFrame then return end
    LoadCache()
    local todo = {}
    EachItem(function(item)
        if not done[item.id] and Indexable(item) then
            -- Tabs first: a setting found on a tab keeps that tab with it,
            -- so jumping to it switches there even after you have left
            -- the page on a different one. The default build fills in
            -- whatever the tabs did not cover.
            -- (its tabs are walked by the build itself)
            todo[#todo + 1] = { item = item }
        end
    end)
    if #todo == 0 then return end
    running = true
    local fresh = {}
    local i = 0
    local function Step()
        -- (keys are arriving: the reading waits, typing stays smooth)
        if GetTime and (GetTime() - lastKey) < TYPE_PAUSE then
            C_Timer.After(0.1, Step)
            return
        end
        i = i + 1
        local job = todo[i]
        if not job then
            running = false
            for id, list in pairs(fresh) do
                index[id] = list
                done[id] = true
                SavePage(id)
            end
            if onDone then pcall(onDone) end
            return
        end
        if not done[job.item.id] then
            local entries = DryRun(job.item, job.alias)
            if entries then
                fresh[job.item.id] = Merge(fresh[job.item.id] or {}, entries)
            end
        end
        C_Timer.After(0, Step)
    end
    C_Timer.After(0, Step)
end

-- ============================================================
-- COMMANDS
-- ============================================================
-- The /rc commands the Commands page lists (RC:VisibleSlashSections,
-- Sidebar_Hooks: the groups whose part is loaded, a command this game
-- version runs). A command with words to fill in (<boss>, [seconds], an
-- (Item,slot)), one of several spellings, or one that clears or resets
-- something is put in the chat box to be finished; the rest run.
local PASTE_WORDS = { "clear", "reset", "cleanup", "confirm", "adopt", "wipe", "uninstall" }
local function CommandText(row)
    -- "/rc move | /rc moveui | /rc unlock": the first spelling
    local text = (row.cmd or ""):match("^%s*(.-)%s*|") or row.cmd or ""
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end
S.CommandText = CommandText

local function PasteOnly(row)
    local text = CommandText(row)
    if row.paste then return true end
    if text:find("[<%[%(|]") then return true end
    local lower = text:lower()
    for _, w in ipairs(PASTE_WORDS) do
        if lower:find(w, 1, true) then return true end
    end
    return false
end
S.PasteOnly = PasteOnly

local function EachCommand(fn)
    local sections = RC.VisibleSlashSections and RC:VisibleSlashSections() or RC.SlashSections or {}
    for _, section in ipairs(sections) do
        for _, row in ipairs(section.rows or {}) do fn(row, section) end
    end
end

-- Run a command result: a complete command runs through its slash
-- handler now; one that needs finishing goes into the chat box.
-- Returns "ran", "pasted" or false.
function S.RunCommand(r)
    local row = r and r.command
    if not row then return false end
    local text = CommandText(row)
    if PasteOnly(row) then
        local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
        local upTo = text:gsub("%s*[<%[%(].*$", "")
        if open then open(upTo .. " ") end
        return "pasted"
    end
    local slash, rest = text:match("^(/%S+)%s*(.-)$")
    if not slash then return false end
    local handler
    if SlashCmdList then
        for name, fn in pairs(SlashCmdList) do
            local i = 1
            while true do
                local sw = _G["SLASH_" .. name .. i]
                if not sw then break end
                if sw:lower() == slash:lower() then handler = fn break end
                i = i + 1
            end
            if handler then break end
        end
    end
    if not handler then return false end
    handler(rest or "")
    return "ran"
end

-- ============================================================
-- RANKING
-- ============================================================
-- One word against one lowercase string. The quality says how it
-- matched: at the start, at a word start, inside a word, as letters in
-- order (a fuzzy hit: "castbar" in "cast bar"), or with one letter wrong.
-- nil when it does not.
local Q_PREFIX, Q_WORD, Q_INSIDE = 100, 85, 65

-- Letters in order. The forward pass (one C find per letter) finds where
-- the earliest full match ends; the backward pass from there finds the
-- latest start, so "stat" in "secondary stat display" lands on "stat" and
-- not on the s of secondary. A match spread over much more than its own
-- length is noise ("cat" across "character settings"), not a hit: slack
-- is how many extra letters the spread may hold, half the word's length
-- unless given. Returns a quality 25..50 by how tight the letters sit.
local function Subseq(hay, w, slack)
    local hl, wl = #hay, #w
    if wl > hl then return nil end
    local pos = 0
    for i = 1, wl do
        pos = hay:find(w:sub(i, i), pos + 1, true)
        if not pos then return nil end
    end
    local last = pos
    local hi, wi = last, wl
    while wi >= 1 do
        if hay:byte(hi) == w:byte(wi) then wi = wi - 1 end
        hi = hi - 1
    end
    local span = last - hi
    if span > wl + (slack or math_max(2, math_floor(wl / 2))) then return nil end
    return 25 + math_floor(25 * wl / span)
end

-- One letter wrong, dropped or doubled: the first letter of the word the
-- forward pass cannot place is left out and the rest must still be found
-- in order, close together.
local function Typo(hay, w)
    local wl = #w
    local pos, stuck = 0, nil
    for i = 1, wl do
        pos = hay:find(w:sub(i, i), pos + 1, true)
        if not pos then stuck = i break end
    end
    if not stuck then return nil end
    local short = w:sub(1, stuck - 1) .. w:sub(stuck + 1)
    if #short < 3 then return nil end
    local q = Subseq(hay, short, 3)
    return q and math_floor(q * 0.6) or nil
end

local function WordQuality(hay, w)
    local i = hay:find(w, 1, true)
    if i then
        if i == 1 then return Q_PREFIX end
        local prev = hay:byte(i - 1)
        if prev == 32 or prev < 48 or (prev > 57 and prev < 65) then return Q_WORD end
        return Q_INSIDE
    end
    local wl = #w
    if wl < 3 then return nil end
    local q = Subseq(hay, w)
    if q then return q end
    if wl >= 4 then return Typo(hay, w) end
    return nil
end
S.WordQuality = WordQuality

-- Every word against the thing itself (own) and, failing that, against
-- the words around it (ctx: its card, tab, page, group) at a quarter of
-- the quality. nil unless every word landed and at least one on the
-- thing itself; otherwise every row of a matching card would come back.
local function Score(own, ctx, tokens)
    local total, hits = 0, 0
    for _, w in ipairs(tokens) do
        local q = WordQuality(own, w)
        if q then
            hits = hits + 1
            total = total + q
        else
            q = ctx and WordQuality(ctx, w)
            if not q then return nil end
            total = total + math_floor(q / 4)
        end
    end
    if hits == 0 then return nil end
    return total
end
S.Score = Score

local function PageHay(item, cat)
    local parts = { (item.name or ""):lower() }
    if cat then parts[#parts + 1] = (cat.name or ""):lower() end
    for _, a in ipairs(item.aliases or {}) do parts[#parts + 1] = a:lower() end
    return table_concat(parts, " ")
end

-- Equal scores: a setting before its section, a section before a
-- command, a command before a tab, a tab before a page.
local KIND_RANK = { row = 1, desc = 1, tip = 1, card = 2, command = 3, tab = 4, page = 5 }

-- Ranked results plus the set of page ids that have something. Each
-- result: item (the menu id), kind, label, score, page, parent, and
-- entry (the indexed line) or command (the Commands page row).
function S.Run(query)
    local tokens = Tokens(query)
    local results, hits = {}, {}
    if #tokens == 0 then return results, hits end
    local phrase = table_concat(tokens, " ")

    -- The Commands page's own lines (a command, what it does) come back as
    -- Command results below, not as settings of that page.
    local cmdLines = {}
    EachCommand(function(row)
        if row.cmd then cmdLines[Clean(row.cmd):lower()] = true end
        if row.desc then cmdLines[Clean(row.desc):lower()] = true end
    end)

    EachItem(function(item, cat)
        if not (item.panel or item.raidKey) or not S.IsVisible(item) then return end
        local pageName = (item.name or ""):lower()
        local catName = cat and (cat.name or ""):lower() or ""
        local score = Score(PageHay(item, cat), nil, tokens)
        if score then
            -- a hit on the aliases alone sits below a setting that names
            -- the word itself; the page's own name counts in full
            if not Score(pageName, nil, tokens) then score = math_floor(score / 2) end
            if pageName:find(phrase, 1, true) then score = score + 30 end
            -- the page whose name is the query is what was asked for
            if pageName == phrase then score = score + 60 end
            results[#results + 1] = { item = item.id, kind = "page", label = item.name,
                score = score, page = item.name, parent = cat and cat.name, order = #results }
            hits[item.id] = true
        end
        for _, e in ipairs(index[item.id] or {}) do
            local ctx = (e.card or ""):lower() .. " " .. (e.tabLabel or ""):lower() .. " "
                .. pageName .. " " .. catName
            local s
            if not (item.id == "commands" and e.kind ~= "card" and cmdLines[(e.label or ""):lower()]) then
                s = Score(e.hay, ctx, tokens)
            end
            if s then
                local label = (e.label or ""):lower()
                if label:find(phrase, 1, true) then s = s + 30 end
                if label == phrase then s = s + 40 end
                if e.kind == "card" then s = s + 4
                elseif e.kind == "desc" then s = s - 10
                elseif e.kind == "tip" then s = s - 8 end
                s = s + math_max(0, 12 - math_floor(#label / 8))
                results[#results + 1] = { entry = e, item = item.id, kind = e.kind,
                    label = e.label, score = s, page = item.name,
                    parent = cat and cat.name, order = #results }
                hits[item.id] = true
            end
        end
        -- the hand-kept tab words (RC.SUBPANEL_ALIASES): extra keywords
        -- that open a tab of this page
        for i, sub in ipairs(RC.SUBPANEL_ALIASES or {}) do
            if sub.parentId == item.id and type(sub.setTab) == "function" then
                -- (a part this game version does not run leaves its words out: Core_Flavor)
                local words = RC.AliasKeywords and RC:AliasKeywords(sub) or sub.keywords
                local hay = table_concat(words or {}, " "):lower() .. " " .. (sub.tabLabel or ""):lower()
                local s = Score(hay, pageName .. " " .. catName, tokens)
                if s then
                    results[#results + 1] = { entry = { kind = "tab", alias = i, tabLabel = sub.tabLabel, label = sub.tabLabel },
                        item = item.id, kind = "tab", label = (sub.tabLabel or item.name), score = math_floor(s / 2) + 3,
                        page = item.name, parent = cat and cat.name, order = #results }
                    hits[item.id] = true
                end
            end
        end
    end)

    -- the /rc commands
    EachCommand(function(row, section)
        local text = CommandText(row)
        -- (every spelling: "/rc moveui" finds "/rc move | /rc moveui")
        local own = (Clean(row.cmd or text) .. " " .. (row.desc or "")):lower()
        local s = Score(own, (section.title or ""):lower(), tokens)
        if s then
            if (row.cmd or text):lower():find(phrase, 1, true) then s = s + 20 end
            results[#results + 1] = { command = row, item = "_commands", kind = "command",
                label = text, score = s, page = RCL["Commands"], parent = section.title, order = #results }
        end
    end)

    table_sort(results, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        local ra, rb = KIND_RANK[a.kind] or 9, KIND_RANK[b.kind] or 9
        if ra ~= rb then return ra < rb end
        return (a.order or 0) < (b.order or 0)
    end)
    local seen, out = {}, {}
    for _, r in ipairs(results) do
        local e = r.entry
        local k = r.item .. "\1" .. (r.label or "") .. "\1" .. ((e and e.card) or "")
            .. "\1" .. tostring(e and (e.tabKey or e.alias))
        if not seen[k] then
            seen[k] = true
            out[#out + 1] = r
        end
    end
    return out, hits
end

-- ============================================================
-- HOW A RESULT READS
-- ============================================================
-- The kind label a result row wears and its breadcrumb ("Group > Page >
-- Tab > Card"), for whatever draws the results.
local KIND_LABEL = { page = "Page", tab = "Section", card = "Section", command = "Command" }
function S.Kind(r)
    return RCL[KIND_LABEL[r.kind] or "Setting"]
end

function S.Crumb(r)
    local bits = {}
    if r.kind == "command" then
        bits[1] = RCL["Commands"]
        if r.command and r.command.desc and r.command.desc ~= "" then bits[2] = r.command.desc end
        return table_concat(bits, "  >  ")
    end
    if r.parent then bits[#bits + 1] = r.parent end
    if r.kind ~= "page" and r.page then bits[#bits + 1] = r.page end
    local e = r.entry
    if e then
        if e.tabLabel then bits[#bits + 1] = e.tabLabel end
        if e.card and r.kind ~= "card" then bits[#bits + 1] = e.card end
    end
    return table_concat(bits, "  >  ")
end

function S.Highlight(text, query, hex)
    local tokens = Tokens(query)
    local lower = text:lower()
    local marks = {}
    for _, w in ipairs(tokens) do
        local s = 1
        while true do
            local a, b = lower:find(w, s, true)
            if not a then break end
            for i = a, b do marks[i] = true end
            s = b + 1
        end
    end
    local out, open = {}, false
    for i = 1, #text do
        if marks[i] and not open then
            out[#out + 1] = "|cff" .. hex
            open = true
        elseif not marks[i] and open then
            out[#out + 1] = "|r"
            open = false
        end
        out[#out + 1] = text:sub(i, i)
    end
    if open then out[#out + 1] = "|r" end
    return table_concat(out)
end

-- After the user opens a page: its default state replaces the indexed
-- default-state entries (tab entries built through aliases are kept).
function S.RefreshFromPage(itemId)
    local outer = RC.sidebarConfigFrame
    local compat = outer and outer.compatFrame
    local item = FindItem(itemId)
    if not (compat and compat.scrollChild and item and done[itemId]) then return end
    local path = S.LivePath()
    local ok, fresh = pcall(Scan, compat.scrollChild, item, nil, path)
    if not ok or not fresh then return end
    local here = PathKey(path)
    local keep = {}
    for _, e in ipairs(index[itemId] or {}) do
        -- (what sits in a shut section is not on the page now; keep it)
        if e.alias or e.fold or (e.tabKey or "") ~= here then keep[#keep + 1] = e end
    end
    index[itemId] = Merge(keep, fresh)
    SavePage(itemId)
end

-- ============================================================
-- JUMPING
-- ============================================================
-- the accent as a colour code, for the kind on a result row
function S.AccentHex()
    local a = RC:GetColor("ui", "accentGold")
    return string_format("%02x%02x%02x", math_floor(a.r * 255 + 0.5),
        math_floor(a.g * 255 + 0.5), math_floor(a.b * 255 + 0.5))
end

-- A gold box over the setting a jump landed on, fading out.
local function Flash(target)
    local host = target.GetParent and target:GetParent()
    if not host or not host.CreateTexture then return end
    local FLAT = RC.UI.FLAT or "Interface\\Buttons\\WHITE8X8"
    local f = CreateFrame("Frame", nil, host)
    local lvl = (target.GetFrameLevel and target:GetFrameLevel()) or host:GetFrameLevel()
    f:SetFrameLevel(lvl + 4)
    f:SetPoint("TOPLEFT", target, "TOPLEFT", -5, 4)
    f:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", 5, -4)
    local gold = RC:GetColor("ui", "accentGold")
    local fill = f:CreateTexture(nil, "BACKGROUND")
    fill:SetAllPoints()
    fill:SetTexture(FLAT)
    fill:SetVertexColor(gold.r, gold.g, gold.b, 0.12)
    f.border = RC.UI:CreateSimpleBorder(f)
    RC.UI:UpdateBorderColor(f.border, gold, 1)
    local ag = f:CreateAnimationGroup()
    local fade = ag:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0)
    fade:SetStartDelay(1.4)
    fade:SetDuration(0.8)
    ag:SetScript("OnFinished", function() f:Hide() end)
    ag:Play()
end

-- The live label for an entry on the page now showing (exact position,
-- real frame), searched by text and card.
local function FindLive(sc, e)
    local best
    local function Walk(frame, card, owner, depth)
        if best or depth > 12 then return end
        local cardHere = card
        if type(frame.titleText) == "string" then cardHere = Clean(frame.titleText) end
        if e.kind == "card" and cardHere == e.label and frame ~= sc and frame.titleText then
            best = frame
            return
        end
        for _, r in ipairs({ frame:GetRegions() }) do
            if r.IsObjectType and r:IsObjectType("FontString") and r:IsVisible() then
                local t = Clean(r:GetText())
                if t == e.label and (not e.card or e.card == cardHere) then
                    best = owner or r
                    return
                end
            end
        end
        for _, c in ipairs({ frame:GetChildren() }) do
            if c:IsVisible() then
                local own = owner
                if not own and cardHere and frame.titleText then own = c end
                Walk(c, cardHere, own, depth + 1)
                if best then return end
            end
        end
    end
    Walk(sc, nil, nil, 0)
    return best
end

local function ScrollTo(outer, e)
    local attempts = 0
    local function Try()
        attempts = attempts + 1
        local compat = outer.compatFrame
        local sc = compat and compat.scrollChild
        local scroll = outer.contentFrame
        local bar = scroll and scroll.scrollBar
        if not (sc and bar) then return end
        local target = FindLive(sc, e)
        local scTop = sc:GetTop()
        local tTop = target and target:GetTop()
        if not (target and scTop and tTop) then
            if attempts < 8 then C_Timer.After(0.05, Try) end
            return
        end
        local _, maxVal = bar:GetMinMaxValues()
        local actualMax = math_max(0, (sc:GetHeight() or 0) - (scroll:GetHeight() or 0))
        if actualMax > (maxVal or 0) then
            bar:SetMinMaxValues(0, actualMax)
            maxVal = actualMax
        end
        local v = math_max(0, math_min(maxVal or 0, (scTop - tTop) - 60))
        bar:SetValue(v)
        if scroll.SetVerticalScroll then scroll:SetVerticalScroll(v) end
        Flash(target)
    end
    C_Timer.After(0.05, Try)
end

function S.JumpTo(r)
    local outer = RC.sidebarConfigFrame
    if not (r and outer) then return end
    local item, cat = FindItem(r.item)
    if not item then return end
    S.searchMode = false
    local e = r.entry
    if e and e.alias then
        local sub = RC.SUBPANEL_ALIASES and RC.SUBPANEL_ALIASES[e.alias]
        if sub and sub.setTab then pcall(sub.setTab, outer) end
    end
    if cat then RC.SidebarState.expandedCategories[cat.id] = true end
    -- a setting inside a customization section: open it first
    if e and e.fold and RC.UI.SetCustomFoldOpen then RC.UI:SetCustomFoldOpen(e.fold, true) end
    RC:SelectSidebarItem(outer, item, cat)
    -- the tabs it was found under, row by row (a row under a tab shows
    -- once that tab is picked)
    if e and e.tabPath then
        for _, st in ipairs(e.tabPath) do
            local g = S.LiveGroup(st.sig)
            local sel = g and ((type(g.group) == "table" and g.group.selected) or g.selected)
            if g and sel ~= st.key and type(g.onClick) == "function" then
                pcall(g.onClick, st.key)
                g.selected = st.key
            end
        end
    end
    if e and e.kind ~= "page" and e.kind ~= "tab" then ScrollTo(outer, e) end
end

-- The tab rows the page on screen drew (newest build), for jumps.
do
    local live = {}
    local rawTabs = RC.UI.CreateTabGroup
    RC.UI.CreateTabGroup = function(selfUI, parentF, opts)
        local g, y = rawTabs(selfUI, parentF, opts)
        local outer = RC.sidebarConfigFrame
        local real = outer and outer.contentScrollChild
        if g and real and parentF == real and parentF ~= scratchChild and type(opts) == "table" and type(opts.tabs) == "table" and opts.searchWalk ~= false then
            local keys, labels = {}, {}
            for i, td in ipairs(opts.tabs) do keys[i] = td.key labels[td.key] = Clean(td.label) end
            live[#live + 1] = { keys = keys, labels = labels, selected = opts.selected, onClick = opts.onClick,
                sig = table_concat(keys, ","), group = g }
        end
        return g, y
    end
    if RC.ClearSidebarContent then
        hooksecurefunc(RC, "ClearSidebarContent", function(_, f)
            local compat = f and f.compatFrame
            if compat and compat.scrollChild and compat.scrollChild ~= scratchChild then
                for i = #live, 1, -1 do live[i] = nil end
            end
        end)
    end
    function S.LiveGroup(sig)
        for i = #live, 1, -1 do if live[i].sig == sig then return live[i] end end
    end
    function S.LivePath()
        local p = {}
        for _, g in ipairs(live) do
            local sel = (type(g.group) == "table" and g.group.selected) or g.selected
            p[#p + 1] = { sig = g.sig, key = sel, label = g.labels[sel], many = #g.keys > 1 }
        end
        return p
    end
end

-- (The results dropdown, the box's typing, Enter, Escape and arrow keys,
-- Ctrl+F and /rc search: Sidebar_SearchBox.lua.)

RC:DebugPrint("Sidebar search loaded", "system")
