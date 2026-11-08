------------------------------------------------------------------------
-- Readycheck - Sidebar Shell: Shared Widgets
-- Building blocks every settings page uses: CreateSettingsCard (the
-- card container - set contentY / call SetContentHeight when the page
-- finishes laying out children), CreateSettingsPageHeader, and the
-- tab-bar builder wrapping RC.UI:CreateTabGroup.
------------------------------------------------------------------------
-- Taint-safe API locals (fallbacks on RC.Compat, built in Core; never write _G)
local RCC = _G.Readycheck
local GetSpellTexture = GetSpellTexture or (RCC and RCC.Compat and RCC.Compat.GetSpellTexture)
local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local table_insert, table_remove, table_sort = table.insert, table.remove, table.sort
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local RC = _G.Readycheck
if not RC then return end
RC._sbs = RC._sbs or {}
local _sbs = RC._sbs

    -- A titled section on a settings page. ZacUI card look: flat
    -- ui.cardBackground fill, 1px ui.borderNormal ring at alpha 0.55
    -- (softer than a widget's - a page of hard black rectangles reads as
    -- a grid), a 3px gold bar down the whole left edge at alpha 0.8, and
    -- the title 12px text.gold at (12, -9). Sits 18px in from the page
    -- edge. card.contentY is the first-control offset (-32).
    function RC:CreateSettingsCard(parent, yPos, title, width)
        local FLAT = (RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8"
        local card = CreateFrame("Frame", nil, parent)
        card:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yPos)
        card:SetPoint("RIGHT", parent, "RIGHT", -18, 0)
        card:SetHeight(50)

        local cardBgColor = self:GetColor("ui", "cardBackground")
        local borderColor = self:GetColor("ui", "borderNormal")

        local bgTexture = card:CreateTexture(nil, "BACKGROUND")
        bgTexture:SetAllPoints()
        bgTexture:SetTexture(FLAT)
        bgTexture:SetVertexColor(cardBgColor.r, cardBgColor.g, cardBgColor.b, cardBgColor.a or 1)

        card.border = RC.UI:CreateSimpleBorder(card)
        RC.UI:UpdateBorderColor(card.border, borderColor, 0.55)

        local accent = card:CreateTexture(nil, "ARTWORK")
        accent:SetPoint("TOPLEFT", card, "TOPLEFT", 0, 0)
        accent:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 0, 0)
        accent:SetWidth(3)
        accent:SetTexture(FLAT)
        local accentColor = self:GetColor("ui", "accentGold")
        accent:SetVertexColor(accentColor.r, accentColor.g, accentColor.b, 0.8)

        -- IN THE /rc WINDOW (5.0) a card is a section of rows on the panel,
        -- as in ZacUI's /zui: no fill, ring or bar; the title at 12, white
        -- 0.41, over a 1 px white 0.02 rule; under the rule the card's rows
        -- on alternating black 0.10 / 0.20 bands (laid when the page sets
        -- the card's height). Every row keeps the place the page gave it.
        local S = RC.UI.S
        local set = RC.UI:InSettings(parent)
        card._rcSet = set or nil

        if title then
            local titleText = self:CreateFontString(card, "OVERLAY", nil, 12)
            titleText:SetPoint("TOPLEFT", card, "TOPLEFT", set and 1 or 12, set and -8 or -9)
            titleText:SetText(title)
            local titleColor = self:GetColor("text", "gold")
            titleText:SetTextColor(titleColor.r, titleColor.g, titleColor.b)
            card.title = titleText
            card.titleText = title
        end

        card.bgTexture = bgTexture
        card.accent = accent
        card.contentY = -32 -- default first-row offset for callers building rows manually

        if set then
            local rule = card:CreateTexture(nil, "BORDER")
            rule:SetTexture(FLAT)
            rule:SetHeight(1)
            rule:SetPoint("TOPLEFT", card, "TOPLEFT", 0, -S.SECTION_RULE_Y)
            rule:SetPoint("TOPRIGHT", card, "TOPRIGHT", 0, -S.SECTION_RULE_Y)
            card.rule = rule
            card.bands = {}
        end

        -- Pages must call this once layout is done; height feeds directly into the
        -- outer scrollbar math via UpdateSidebarScrollbar.
        -- The same 14 px under the last row on every card: the row the page
        -- built last is measured, and space the page counted past it (the
        -- pitch to a next row that never came) is not kept. A piece hung
        -- off the card's bottom edge (fills, covers) is not a row. When
        -- nothing can be measured yet, the page's own height stands.
        local function AnchoredToBottom(o)
            for i = 1, (o.GetNumPoints and o:GetNumPoints() or 0) do
                local _, rel, rp = o:GetPoint(i)
                if (rel == card or rel == nil) and rp and rp:find("BOTTOM") then return true end
            end
            return false
        end
        local function ContentBottom()
            local top = card:GetTop()
            if not top then return nil end
            local low
            local function Take(o)
                if o == card.bgTexture or o == card.accent or not o:IsShown() or AnchoredToBottom(o) then return end
                if (o.GetNumPoints and o:GetNumPoints() or 0) == 0 then return end
                local b = o:GetBottom()
                local t = o:GetTop()
                if not (b and t) or t - b <= 0.5 then return end
                if not low or b < low then low = b end
            end
            for _, o in ipairs({ card:GetRegions() }) do
                if not (o.GetObjectType and o:GetObjectType() == "Texture" and (o:GetDrawLayer() == "BACKGROUND" or o:GetDrawLayer() == "BORDER")) then Take(o) end
            end
            for _, o in ipairs({ card:GetChildren() }) do
                if (o.GetNumPoints and o:GetNumPoints() or 0) == 0 then
                    -- a bare holder (a checkbox's): what is inside it counts
                    for _, k in ipairs({ o:GetChildren() }) do Take(k) end
                else
                    Take(o)
                end
            end
            return low and (top - low) or nil
        end
        -- THE ROW BANDS: what the page put under the rule, grouped into rows
        -- by where it sits (pieces that overlap in height are one row), each
        -- row a band from halfway to the row above to halfway to the next.
        local function LayBands()
            if not card._rcSet then return end
            local top = card:GetTop()
            local h = card:GetHeight() or 0
            for _, b in ipairs(card.bands) do b:Hide() end
            if not top or h <= S.SECTION_RULE_Y + 2 then return end
            local spans = {}
            local function Take(o)
                if o == card.bgTexture or o == card.accent or o == card.title or o == card.rule or not o:IsShown() then return end
                if AnchoredToBottom(o) or (o.GetNumPoints and o:GetNumPoints() or 0) == 0 then return end
                local b, t = o:GetBottom(), o:GetTop()
                if not (b and t) or t - b < 4 then return end
                local y0, y1 = top - t, top - b
                if y1 <= S.SECTION_RULE_Y + 1 or y0 >= h then return end
                spans[#spans + 1] = { math.max(y0, S.SECTION_RULE_Y + 1), math.min(y1, h) }
            end
            for _, o in ipairs({ card:GetRegions() }) do
                if not (o.GetObjectType and o:GetObjectType() == "Texture" and (o:GetDrawLayer() == "BACKGROUND" or o:GetDrawLayer() == "BORDER")) then Take(o) end
            end
            for _, o in ipairs({ card:GetChildren() }) do
                if (o.GetNumPoints and o:GetNumPoints() or 0) == 0 then
                    for _, k in ipairs({ o:GetChildren() }) do Take(k) end
                elseif not o._rcLockCover then
                    Take(o)
                end
            end
            if #spans == 0 then return end
            table.sort(spans, function(a, b) return a[1] < b[1] end)
            local rows = {}
            for _, sp in ipairs(spans) do
                local last = rows[#rows]
                if last and sp[1] < last[2] - 2 then
                    if sp[2] > last[2] then last[2] = sp[2] end
                else
                    rows[#rows + 1] = { sp[1], sp[2] }
                end
            end
            local from = S.SECTION_RULE_Y + 1
            for i, row in ipairs(rows) do
                local nxt = rows[i + 1]
                local to = nxt and math.floor((row[2] + nxt[1]) / 2 + 0.5) or h
                local band = card.bands[i]
                if not band then
                    band = card:CreateTexture(nil, "BACKGROUND", nil, 1)
                    band:SetTexture(FLAT)
                    card.bands[i] = band
                end
                band:ClearAllPoints()
                band:SetPoint("TOPLEFT", card, "TOPLEFT", 0, -from)
                band:SetPoint("TOPRIGHT", card, "TOPRIGHT", 0, -from)
                band:SetHeight(math.max(1, to - from))
                band:SetVertexColor(RC.UI:SCol("shade", (i % 2 == 1) and S.ROW_ODD or S.ROW_EVEN))
                band:Show()
                from = to
            end
        end
        card.LayBands = LayBands

        function card:SetContentHeight(h)
            local measured = ContentBottom()
            if measured and measured > 0 and measured < h then h = measured end
            self:SetHeight(math.max(36, h + 14))
            if self._rcSet then LayBands() end
        end

        -- Repaints fill/ring/accent/title from the theme (RefreshUIColors).
        function card:Repaint()
            if self._rcSet then
                self.bgTexture:SetVertexColor(0, 0, 0, 0)
                RC.UI:UpdateBorderColor(self.border, RC:GetColor("ui", "borderNormal"), 0)
                self.accent:SetVertexColor(0, 0, 0, 0)
                self.rule:SetVertexColor(RC.UI:SCol("text", S.SECTION_RULE_A))
                if self.title then self.title:SetTextColor(RC.UI:SCol("text", S.SECTION_A)) end
                for i, b in ipairs(self.bands) do
                    b:SetVertexColor(RC.UI:SCol("shade", (i % 2 == 1) and S.ROW_ODD or S.ROW_EVEN))
                end
                return
            end
            local cb = RC:GetColor("ui", "cardBackground")
            self.bgTexture:SetVertexColor(cb.r, cb.g, cb.b, cb.a or 1)
            RC.UI:UpdateBorderColor(self.border, RC:GetColor("ui", "borderNormal"), 0.55)
            local ac = RC:GetColor("ui", "accentGold")
            self.accent:SetVertexColor(ac.r, ac.g, ac.b, 0.8)
            if self.title then
                local tc = RC:GetColor("text", "gold")
                self.title:SetTextColor(tc.r, tc.g, tc.b)
            end
        end

        card._rcSettingsCard = true
        if set then card:Repaint() end
        return card
    end

    -- A page whose bar (or feature) is switched off: every settings card on
    -- it is greyed and takes no clicks, with a line saying why, so nothing
    -- can be changed that would not show anyway. liveCard/liveHeight keep
    -- the top of one card working - the card holding the on switch, down
    -- to just under it. The covers belong to the cards, so the next page
    -- build (every tab click and every toggle rebuilds) takes them away.
    function RC:LockSettingsCards(parent, message, liveCard, liveHeight)
        if not parent then return end
        local FLAT = (RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8"
        local shadeCol = self:GetColor("ui", "cardBackground")
        local gray = self:GetColor("text", "gray")
        local first = true
        for _, card in ipairs({ parent:GetChildren() }) do
            if card._rcSettingsCard then
                local top = (card == liveCard) and (liveHeight or 0) or 0
                local cover = CreateFrame("Frame", nil, card)
                cover:SetPoint("TOPLEFT", card, "TOPLEFT", 0, -top)
                cover:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", 0, 0)
                cover:SetFrameLevel(card:GetFrameLevel() + 40)
                cover:EnableMouse(true)
                local shade = cover:CreateTexture(nil, "OVERLAY")
                shade:SetAllPoints()
                shade:SetTexture(FLAT)
                shade:SetVertexColor(shadeCol.r, shadeCol.g, shadeCol.b, 0.72)
                if card._rcSet then shade:SetVertexColor(RC.UI:SCol("windowBackground", 0.72)) end
                if first and message then
                    -- the note sits in its own solid strip, so it never lies
                    -- on top of a dimmed row or the card title: at the top of
                    -- the cover under a live row, else just below the title
                    local bandTop = (card == liveCard) and 0 or 26
                    local band = cover:CreateTexture(nil, "OVERLAY", nil, 1)
                    band:SetPoint("TOPLEFT", cover, "TOPLEFT", 0, -bandTop)
                    band:SetPoint("TOPRIGHT", cover, "TOPRIGHT", 0, -bandTop)
                    band:SetHeight(20)
                    band:SetTexture(FLAT)
                    band:SetVertexColor(shadeCol.r, shadeCol.g, shadeCol.b, 0.97)
                    if card._rcSet then band:SetVertexColor(RC.UI:SCol("windowBackground", 0.97)) end
                    local note = self:CreateFontString(cover, "OVERLAY", nil, 10)
                    note:SetDrawLayer("OVERLAY", 2)
                    note:SetPoint("LEFT", band, "LEFT", 14, 0)
                    note:SetPoint("RIGHT", band, "RIGHT", -14, 0)
                    note:SetWordWrap(false)
                    note:SetJustifyH("LEFT")
                    note:SetText(message)
                    note:SetTextColor(gray.r, gray.g, gray.b)
                    first = false
                end
                cover:SetScript("OnEnter", function(c)
                    if not message then return end
                    GameTooltip:SetOwner(c, "ANCHOR_CURSOR")
                    GameTooltip:SetText(message, gray.r, gray.g, gray.b, 1, true)
                    GameTooltip:Show()
                end)
                cover:SetScript("OnLeave", function() GameTooltip:Hide() end)
                card._rcLockCover = cover
            end
        end
    end

    function RC:ScrollSidebarToCard(outerFrame, cardTitle)
        if not outerFrame or not cardTitle then return end

        -- Retries because the target card may not exist yet on the frame right after a
        -- page swap; gives up after 6 tries (~0.3s).
        local attempts = 0
        local function tryScroll()
            attempts = attempts + 1
            local compatFrame = outerFrame.compatFrame
            if not compatFrame or not compatFrame.scrollChild then return end
            local sc = compatFrame.scrollChild

            -- (case-blind: card titles are sentence case now, and an old
            -- Title Case target still lands on its card)
            local want = string.lower(cardTitle)
            local target
            local function findIn(parent)
                for _, child in ipairs({parent:GetChildren()}) do
                    if type(child.titleText) == "string" and string.lower(child.titleText) == want then
                        return child
                    end
                end
                for _, child in ipairs({parent:GetChildren()}) do
                    local found = findIn(child)
                    if found then return found end
                end
                return nil
            end
            target = findIn(sc)

            if not target then
                if attempts < 6 then C_Timer.After(0.05, tryScroll) end
                return
            end

            local scTop   = sc:GetTop()
            local cardTop = target:GetTop()
            if not scTop or not cardTop then
                if attempts < 6 then C_Timer.After(0.05, tryScroll) end
                return
            end
            local offset = scTop - cardTop

            local scrollFrame = outerFrame.contentFrame
            local scrollBar   = scrollFrame and scrollFrame.scrollBar
            if not scrollBar then return end

            local _, maxVal = scrollBar:GetMinMaxValues()
            local scChildHeight = sc:GetHeight() or 0
            local scFrameHeight = scrollFrame:GetHeight() or 0
            local actualMax = math.max(0, scChildHeight - scFrameHeight)
            if actualMax > (maxVal or 0) then
                scrollBar:SetMinMaxValues(0, actualMax)
                maxVal = actualMax
            end

            local target_val = math.max(0, math.min(maxVal or 0, offset - 15))
            scrollBar:SetValue(target_val)
            if scrollFrame.SetVerticalScroll then
                scrollFrame:SetVerticalScroll(target_val)
            end
        end

        C_Timer.After(0.05, tryScroll)
    end

    -- Page header: title 15px gold, optional 11px gray subtitle under it,
    -- and a 1px gold rule (alpha 0.6) across the bottom. Height is
    -- measured from the subtitle so a two-line sentence never has the
    -- rule drawn through it. Returns (frame, nextY).
    -- In the /rc window (5.0) it is the window's header, as in ZacUI's
    -- /zui: the title at 36, white, 20 under the header's top (35 under
    -- the window's when it sits 15 down, as pages put it), the line under
    -- it at 14, white 0.53, two lines at most, no icon and no rule; 113
    -- tall at least, so pinned (UIF_Preview) the page starts at 138.
    local function SetPageHeader(self, parent, yPos, title, subtitle, iconPath)
        local S = RC.UI.S
        local headerFrame = CreateFrame("Frame", nil, parent)
        headerFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yPos)
        headerFrame:SetPoint("RIGHT", parent, "RIGHT", -18, 0)
        headerFrame._rcSet = true
        local titleText = self:CreateFontString(headerFrame, "OVERLAY", nil, S.F_TITLE)
        titleText:SetPoint("TOPLEFT", headerFrame, "TOPLEFT", 0, -20)
        titleText:SetPoint("RIGHT", headerFrame, "RIGHT", 0, 0)
        titleText:SetJustifyH("LEFT")
        titleText:SetWordWrap(false)
        titleText:SetText(title)
        headerFrame.title = titleText
        local need = 20 + math.ceil(titleText:GetStringHeight() or S.F_TITLE) + 16
        if subtitle then
            local subtitleText = self:CreateFontString(headerFrame, "OVERLAY", nil, S.F_DESC)
            subtitleText:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 2, -12)
            subtitleText:SetPoint("RIGHT", headerFrame, "RIGHT", 0, 0)
            subtitleText:SetJustifyH("LEFT")
            subtitleText:SetWordWrap(true)
            if subtitleText.SetMaxLines then subtitleText:SetMaxLines(2) end
            subtitleText:SetText(subtitle)
            headerFrame.subtitle = subtitleText
            need = need + 12 + math.ceil(math.min(subtitleText:GetStringHeight() or S.F_DESC, 2.6 * S.F_DESC))
        end
        local height = math.max(S.HEADER - 25, need)
        headerFrame:SetHeight(height)
        -- (kept, hidden: older code reads them)
        if iconPath then
            local icon = headerFrame:CreateTexture(nil, "ARTWORK")
            icon:SetSize(1, 1)
            icon:SetPoint("TOPLEFT")
            icon:Hide()
            headerFrame.icon = icon
        end
        local line = headerFrame:CreateTexture(nil, "BORDER")
        line:SetPoint("BOTTOMLEFT", headerFrame, "BOTTOMLEFT", 0, 0)
        line:SetPoint("BOTTOMRIGHT", headerFrame, "BOTTOMRIGHT", 0, 0)
        line:SetHeight(1)
        line:Hide()
        headerFrame.accentLine = line
        function headerFrame:Repaint()
            self.title:SetTextColor(RC.UI:SCol("text", 1))
            if self.subtitle then self.subtitle:SetTextColor(RC.UI:SCol("text", S.DIM_A)) end
        end
        headerFrame:Repaint()
        return headerFrame, yPos - height - 12
    end

    function RC:CreateSettingsPageHeader(parent, yPos, title, subtitle, iconPath)
        if RC.UI:InSettings(parent) then return SetPageHeader(self, parent, yPos, title, subtitle, iconPath) end
        local FLAT = (RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8"
        local headerFrame = CreateFrame("Frame", nil, parent)
        headerFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yPos)
        headerFrame:SetPoint("RIGHT", parent, "RIGHT", -18, 0)
        headerFrame:SetHeight(30)

        local startX = 0

        if iconPath then
            local icon = headerFrame:CreateTexture(nil, "ARTWORK")
            icon:SetSize(24, 24)
            icon:SetPoint("TOPLEFT", headerFrame, "TOPLEFT", 0, -1)
            icon:SetTexture(iconPath)
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            startX = 32
            headerFrame.icon = icon
        end

        local titleText = self:CreateFontString(headerFrame, "OVERLAY", nil, 15)
        titleText:SetPoint("TOPLEFT", headerFrame, "TOPLEFT", startX, -2)
        titleText:SetText(title)
        local titleColor = self:GetColor("text", "gold")
        titleText:SetTextColor(titleColor.r, titleColor.g, titleColor.b)
        headerFrame.title = titleText

        local height = 30
        if subtitle then
            local subtitleText = self:CreateFontString(headerFrame, "OVERLAY", nil, 11)
            subtitleText:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 0, -4)
            subtitleText:SetPoint("RIGHT", headerFrame, "RIGHT", 0, 0)
            subtitleText:SetJustifyH("LEFT")
            subtitleText:SetWordWrap(true)
            subtitleText:SetText(subtitle)
            local grayColor = self:GetColor("text", "gray")
            subtitleText:SetTextColor(grayColor.r, grayColor.g, grayColor.b)
            headerFrame.subtitle = subtitleText
            height = 26 + math.max(12, subtitleText:GetStringHeight() or 12) + 6
        end
        headerFrame:SetHeight(height)

        local line = headerFrame:CreateTexture(nil, "ARTWORK")
        line:SetPoint("BOTTOMLEFT", headerFrame, "BOTTOMLEFT", 0, 0)
        line:SetPoint("BOTTOMRIGHT", headerFrame, "BOTTOMRIGHT", 0, 0)
        line:SetHeight(1)
        line:SetTexture(FLAT)
        local accentColor = self:GetColor("ui", "accentGold")
        line:SetVertexColor(accentColor.r, accentColor.g, accentColor.b, 0.6)
        headerFrame.accentLine = line

        function headerFrame:Repaint()
            local tc = RC:GetColor("text", "gold")
            self.title:SetTextColor(tc.r, tc.g, tc.b)
            if self.subtitle then
                local gc = RC:GetColor("text", "gray")
                self.subtitle:SetTextColor(gc.r, gc.g, gc.b)
            end
            local ac = RC:GetColor("ui", "accentGold")
            self.accentLine:SetVertexColor(ac.r, ac.g, ac.b, 0.6)
        end

        return headerFrame, yPos - height - 12
    end

    function RC:CreateXCloseButton(parent, size, onClick)
        return RC.UI:CreateXCloseButton(parent, size, onClick)
    end

    function RC:BuildSettingsTabBar(parent, yPos, tabs, selectedKey, onClick)
        local defs = {}
        for i, td in ipairs(tabs) do defs[i] = { key = td[1], label = td[2] } end
        -- (in the /rc window: the window's 40 px tab bar, 10 above the page)
        local bar = RC.UI:InSettings(parent)
        local _, newY = RC.UI:CreateTabGroup(parent, {
            y = yPos, tabs = defs, selected = selectedKey, onClick = onClick,
            inset = 18, bar = bar,
            advance = bar and (RC.UI.S.TABS + RC.UI.S.TOP_PAD) or (22 + 12), -- tab height + gap before content
        })
        return newY
    end

    RC.appearanceTab = RC.appearanceTab or "fonts"
