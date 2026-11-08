------------------------------------------------------------------------
-- Readycheck - Sidebar Shell: Import / Export Dialogs
-- UI for ExportSelectedSettings/ImportAllSettings (PM_Export.lua): strings
-- are RCS2 (LibDeflate-compressed) or legacy WRS1 (plain base64), each
-- prefixed accordingly. Import data is untrusted - ImportAllSettings
-- allowlists keys and type-checks each value before writing to db.
-- Reload only fires on a successful import that asks for one.
-- ONE IMPORT WINDOW: RC:ShowUniversalImport is what every "Import" button
-- in the addon opens - settings, raid profiles, routes, notes, custom
-- reminders. It names whatever is pasted (RC:IdentifyImport) and imports
-- it through its own importer (RC:ImportAny), wherever it was opened.
------------------------------------------------------------------------
-- Taint-safe API locals (fallbacks on RC.Compat, built in Core; never write _G)
local pairs, ipairs = pairs, ipairs
local CreateFrame = CreateFrame
local RC = _G.Readycheck
if not RC then return end
RC._sbs = RC._sbs or {}
local _sbs = RC._sbs
local TEXT = _sbs.TEXT

    function RC:ShowSidebarProfileExport(frame)
        self:ClearSidebarContent(self.sidebarConfigFrame)
        local parent = frame.scrollChild
        local yPos = -20

        local headerFrame, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Import / Export"],
            RCL["Transfer settings between characters"], "Interface\\Icons\\INV_Misc_Note_01")
        yPos = newY

        local exportCard = self:CreateSettingsCard(parent, yPos, RCL["Export settings"])
        local cardY = -32

        local exportInfo = self:CreateFontString(exportCard, "OVERLAY", nil, 10)
        exportInfo:SetPoint("TOPLEFT", exportCard, "TOPLEFT", 14, cardY)
        exportInfo:SetWidth(exportCard:GetWidth() - 30)
        exportInfo:SetText(RCL["Choose what to include in the export string."])
        exportInfo:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
        cardY = cardY - 22

        -- Retired categories stay in RC.EXPORT_CATEGORIES for backward key mapping but are
        -- hidden from the export picker, as are categories whose owning
        -- addon (cat.addon) is not loaded on this install.
        local selectedCats = {}
        local cats = {}
        for _, cat in ipairs(RC.EXPORT_CATEGORIES or {}) do
            if not cat.retired and (not RC.IsSettingCategoryAvailable or RC:IsSettingCategoryAvailable(cat)) then
                cats[#cats + 1] = cat
                selectedCats[cat.id] = true
            end
        end

        local selAllBtn = self.UI:CreateStyledButton(exportCard, RCL["All"], 40, 18)
        selAllBtn:SetPoint("TOPLEFT", exportCard, "TOPLEFT", 14, cardY)
        local selNoneBtn = self.UI:CreateStyledButton(exportCard, RCL["None"], 44, 18)
        selNoneBtn:SetPoint("LEFT", selAllBtn, "RIGHT", 4, 0)
        cardY = cardY - 24

        local checkboxes = {}
        local colW = math.floor((exportCard:GetWidth() - 30) / 2)
        local col = 0
        local lastGroup = nil
        local accentColor = self:GetColor("ui", "accentGold")

        for i, cat in ipairs(cats) do
            local groupName = cat.group or "Other"
            if groupName ~= lastGroup then
                if col ~= 0 then col = 0; cardY = cardY - 22 end
                if lastGroup ~= nil then cardY = cardY - 6 end
                local hdr = self:CreateFontString(exportCard, "OVERLAY", nil, 11)
                hdr:SetPoint("TOPLEFT", exportCard, "TOPLEFT", 14, cardY)
                hdr:SetText(groupName)
                hdr:SetTextColor(accentColor.r, accentColor.g, accentColor.b)
                cardY = cardY - 18
                lastGroup = groupName
            end

            local cx = 15 + (col * colW)
            local cb = self.UI:CreateCheckbox(exportCard, cat.label, selectedCats[cat.id])
            cb:SetPoint("TOPLEFT", exportCard, "TOPLEFT", cx, cardY)
            local catId = cat.id
            cb:SetScript("OnClick", function()
                selectedCats[catId] = cb:GetChecked()
                self:ForceCheckboxUpdate(cb, selectedCats[catId])
            end)
            checkboxes[cat.id] = cb
            col = col + 1
            if col >= 2 then col = 0; cardY = cardY - 22 end
        end
        if col ~= 0 then cardY = cardY - 22 end
        cardY = cardY - 6

        selAllBtn:SetScript("OnClick", function()
            for _, cat in ipairs(cats) do
                selectedCats[cat.id] = true
                if checkboxes[cat.id] then self:ForceCheckboxUpdate(checkboxes[cat.id], true) end
            end
        end)
        selNoneBtn:SetScript("OnClick", function()
            for _, cat in ipairs(cats) do
                selectedCats[cat.id] = false
                if checkboxes[cat.id] then self:ForceCheckboxUpdate(checkboxes[cat.id], false) end
            end
        end)

        local exportBtn = self.UI:CreateStyledButton(exportCard, RCL["Export Selected"], 140, 28)
        exportBtn:SetPoint("TOPLEFT", exportCard, "TOPLEFT", 14, cardY)
        exportBtn:SetScript("OnClick", function()
            local selected = {}
            for id, on in pairs(selectedCats) do if on then table.insert(selected, id) end end
            if #selected == 0 then RC:Print(RCL["Select at least one category to export."]); return end
            local exportString = RC:ExportSelectedSettings(selected)
            if exportString then RC:ShowExportDialog(exportString) end
        end)
        cardY = cardY - 40

        local div = exportCard:CreateTexture(nil, "ARTWORK")
        do local _bn=RC:GetColor("ui","borderNormal"); div:SetColorTexture(_bn.r,_bn.g,_bn.b,_bn.a or 1) end; div:SetHeight(1)
        div:SetPoint("TOPLEFT", exportCard, "TOPLEFT", 10, cardY)
        div:SetPoint("TOPRIGHT", exportCard, "TOPRIGHT", -10, cardY)
        cardY = cardY - 14

        local importLbl = self:CreateFontString(exportCard, "OVERLAY", nil, 11)
        importLbl:SetPoint("TOPLEFT", exportCard, "TOPLEFT", 14, cardY)
        importLbl:SetText(RCL["Import"])
        importLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
        cardY = cardY - 18

        -- Mirrors ImportAllSettings (PM_Export.lua): each category in the
        -- string replaces that category on the current character; anything
        -- not in the string is left alone, then the UI reloads.
        cardY = RC.UI:CreateHelpLine(exportCard, 14, cardY, RCL["Paste an export string to restore settings. Only the categories in the string are replaced on this character; everything else is kept. The UI reloads afterwards. Any other Readycheck export - a raid profile, a route, notes, a custom reminder - can be pasted here too; the window says what it is before anything is imported."],
            { short = RCL["Paste an export string: only the categories in it are replaced, then the UI reloads."], title = RCL["Import"], gap = 12 })

        local importBtn = self.UI:CreateStyledButton(exportCard, RCL["Import..."], 140, 28)
        importBtn:SetPoint("TOPLEFT", exportCard, "TOPLEFT", 14, cardY)
        importBtn:SetScript("OnClick", function() RC:ShowUniversalImport({ from = "settings" }) end)
        cardY = cardY - 40

        exportCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - exportCard:GetHeight() - 15

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame, math.abs(yPos))
    end

    -- Shared chrome for the three import/export dialogs below: named,
    -- movable DIALOG-strata frame with themed background, simple border,
    -- draggable title bar, X close and a padded content region. ESC closes
    -- through RC.UI:RegisterEscapeClose (UISpecialFrames) - no per-dialog
    -- OnKeyDown handler.
    local function BuildDialogFrame(globalName, width, height, titleLabel)
        local frame = CreateFrame("Frame", globalName, UIParent, "BackdropTemplate")
        frame:SetSize(width, height)
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        frame:SetFrameStrata("DIALOG")
        frame:SetToplevel(true)
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:SetClampedToScreen(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", frame.StartMoving)
        frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
        frame:SetScript("OnMouseDown", function(self) self:Raise() end)

        RC.UI:RegisterEscapeClose(globalName)

        local windowBgColor = RC:GetColor("ui", "windowBackground")
        local bg = frame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(windowBgColor.r, windowBgColor.g, windowBgColor.b, windowBgColor.a or 1)

        RC.UI:CreateSimpleBorder(frame)

        -- 30px title bar, 15px gold title, 22px chromeless X: the same
        -- shell as the config window.
        local titleBar = CreateFrame("Frame", nil, frame)
        titleBar:SetHeight(30)
        titleBar:SetPoint("TOPLEFT", 1, -1)
        titleBar:SetPoint("TOPRIGHT", -1, -1)
        titleBar:EnableMouse(true)
        titleBar:RegisterForDrag("LeftButton")
        titleBar:SetScript("OnDragStart", function() frame:StartMoving() end)
        titleBar:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)

        local headerBgColor = RC:GetColor("ui", "headerBackground")
        local titleBg = titleBar:CreateTexture(nil, "BACKGROUND")
        titleBg:SetAllPoints()
        titleBg:SetTexture(RC.UI.FLAT)
        titleBg:SetVertexColor(headerBgColor.r, headerBgColor.g, headerBgColor.b, 1)

        local accentColor = RC:GetColor("ui", "accentGold")
        local titleAccent = titleBar:CreateTexture(nil, "ARTWORK")
        titleAccent:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 0, 0)
        titleAccent:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
        titleAccent:SetHeight(1)
        titleAccent:SetColorTexture(accentColor.r, accentColor.g, accentColor.b, 0.6)
        if RC.UI.ApplyHeaderArt then
            titleAccent:Hide()
            RC.UI:ApplyHeaderArt(titleBar, { fill = titleBg, stepX = 160 })
        end

        local headerTextColor = RC:GetColor("ui", "headerText")
        local titleText = RC:CreateFontString(titleBar, "OVERLAY", nil, 15, "")
        titleText:SetPoint("LEFT", 10, 0)
        titleText:SetText(titleLabel)
        titleText:SetTextColor(headerTextColor.r, headerTextColor.g, headerTextColor.b)
        frame.titleText = titleText

        local closeBtn = RC.UI:CreateXCloseButton(titleBar, 22, function() frame:Hide() end)
        closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -5, 0)

        local content = CreateFrame("Frame", nil, frame)
        content:SetPoint("TOPLEFT", 15, -42)
        content:SetPoint("BOTTOMRIGHT", -15, 15)
        frame.content = content
        -- the 5.0 popup look (UIF_Dialogs)
        RC.UI:SkinPopup(frame, { fill = bg, header = titleBar, title = titleText, close = closeBtn })

        return frame, content
    end

    function RC:ShowExportDialog(exportString)
        if not self.exportDialogFrame then
            local frame, content = BuildDialogFrame("WRExportDialog", 400, 160, RCL["Export Settings"])

            local instr = self:CreateFontString(content, "OVERLAY", nil, 10)
            instr:SetPoint("TOPLEFT", 0, 0)
            instr:SetText(RCL["Copy this string to share your settings:"])
            instr:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])

            -- 0/absent maxLetters = no length cap; compressed export strings can be long.
            local editFrame = self.UI:CreateStyledEditBox(content, { height = 26, font = 10 })
            editFrame:SetPoint("TOPLEFT", 0, -18)
            editFrame:SetPoint("RIGHT", 0, 0)
            frame.editBox = editFrame.editBox

            local doneBtn = self.UI:CreateStyledButton(content, RCL["Close"], 80, 26)
            doneBtn:SetPoint("BOTTOMRIGHT", 0, 0)
            doneBtn:SetScript("OnClick", function() frame:Hide() end)
            RC.UI:SkinPopup(frame, { primary = doneBtn })

            self.exportDialogFrame = frame
        end

        self.exportDialogFrame.editBox:SetText(exportString or "")
        self.exportDialogFrame.editBox:HighlightText()
        if not self.exportDialogFrame:IsShown() then RC.UI:PopIn(self.exportDialogFrame, 0.12) end
        self.exportDialogFrame:Raise()
        self.exportDialogFrame.editBox:SetFocus()
    end

    -- THE ONE IMPORT WINDOW. ctx (all optional):
    --   from      which page opened it; only used for the title
    --   title     window title (default "Import")
    --   raidName  the route page it was opened from - a pasted route lands
    --             on that raid instead of the raid named in the string
    --   onDone    function(result) after a successful import that does not
    --             reload; result is RC:ImportAny's (result.kind says what
    --             was imported, which need not be what the page expected)
    --
    -- Multi-line on purpose: notes and routes are several lines, and a
    -- one-line box throws the line breaks away.
    --
    -- NO SECURE BUTTON. The old settings dialog reloaded through a
    -- SecureActionButton macro; that made the whole window a protected
    -- frame, which cannot be opened or closed in combat - acceptable for
    -- one dialog, not for the window every Import button now opens. A
    -- reload is ReloadUI(), exactly as the config window's own Reload
    -- button does it, and only after an import that asks for one.
    function RC:ShowUniversalImport(ctx)
        ctx = type(ctx) == "table" and ctx or {}
        local frame = self.universalImportFrame
        if not frame then
            local content
            frame, content = BuildDialogFrame("WRUniversalImportDialog", 500, 378, RCL["Import"])

            local hint = self:CreateFontString(content, "OVERLAY", nil, 10)
            hint:SetPoint("TOPLEFT", 0, 0)
            hint:SetPoint("RIGHT", content, "RIGHT", 0, 0)
            hint:SetHeight(24)
            hint:SetJustifyH("LEFT")
            hint:SetJustifyV("TOP")
            hint:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
            frame.hint = hint

            -- What the paste is, what it carries, what Import will do.
            local what = self:CreateFontString(content, "OVERLAY", nil, 12)
            what:SetPoint("TOPLEFT", 0, -160)
            what:SetPoint("RIGHT", content, "RIGHT", 0, 0)
            what:SetJustifyH("LEFT")
            what:SetWordWrap(false)
            frame.what = what

            local detail = self:CreateFontString(content, "OVERLAY", nil, 10)
            detail:SetPoint("TOPLEFT", 0, -178)
            detail:SetPoint("RIGHT", content, "RIGHT", 0, 0)
            detail:SetHeight(38)
            detail:SetJustifyH("LEFT")
            detail:SetJustifyV("TOP")
            detail:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            frame.detail = detail

            local effect = self:CreateFontString(content, "OVERLAY", nil, 10)
            effect:SetPoint("TOPLEFT", 0, -220)
            effect:SetPoint("RIGHT", content, "RIGHT", 0, 0)
            effect:SetHeight(26)
            effect:SetJustifyH("LEFT")
            effect:SetJustifyV("TOP")
            frame.effect = effect

            -- A raid profile can be renamed on the way in.
            local nameLabel = self:CreateFontString(content, "OVERLAY", nil, 10)
            nameLabel:SetPoint("TOPLEFT", 0, -256)
            nameLabel:SetText(RCL["Save as:"])
            nameLabel:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
            local nameFrame = self.UI:CreateStyledEditBox(content, { height = 22, font = 10, maxLetters = 64 })
            nameFrame:SetPoint("TOPLEFT", 60, -251)
            nameFrame:SetPoint("RIGHT", content, "RIGHT", 0, 0)
            frame.nameLabel, frame.nameFrame, frame.nameBox = nameLabel, nameFrame, nameFrame.editBox

            -- Paints the three lines from an IdentifyImport result.
            local function Show(info)
                frame.info = info
                local gray = RC:GetColor("text", "gray")
                local gold = RC:GetColor("ui", "accentGold")
                local red  = RC:GetColor("text", "red")
                local norm = RC:GetColor("text", "normal")
                if not info or info.kind == "empty" then
                    what:SetText(RCL["Nothing pasted yet."])
                    what:SetTextColor(gray.r, gray.g, gray.b)
                    detail:SetText("")
                    effect:SetText("")
                else
                    what:SetText(info.title or "")
                    if info.kind == "unknown" then
                        what:SetTextColor(red.r, red.g, red.b)
                    else
                        what:SetTextColor(gold.r, gold.g, gold.b)
                    end
                    detail:SetText(table.concat(info.lines or {}, "\n"))
                    if info.ready then
                        effect:SetText(RCL["Import will: "] .. tostring(info.effect or ""))
                        if info.reload then
                            effect:SetTextColor(red.r, red.g, red.b)
                        else
                            effect:SetTextColor(norm.r, norm.g, norm.b)
                        end
                    else
                        effect:SetText(tostring(info.problem or ""))
                        effect:SetTextColor(red.r, red.g, red.b)
                    end
                end
                local wants = info and info.ready and info.wantsName
                nameLabel:SetShown(wants and true or false)
                nameFrame:SetShown(wants and true or false)
                if wants and frame._namedFor ~= info.text then
                    frame._namedFor = info.text
                    frame.nameBox:SetText(info.suggestedName or "")
                end
                if frame.importBtn then
                    local ready = info and info.ready and true or false
                    RC.UI:SetButtonText(frame.importBtn, (ready and info.reload)
                        and RCL["Import & Reload"] or RCL["Import"])
                    frame.importBtn:SetActive(ready)
                end
            end
            frame.ShowInfo = Show

            -- Describing a paste decodes it, so it waits until the text has
            -- been still for a moment instead of running per keystroke.
            local function Identify()
                local text = frame.editBox:GetText() or ""
                if frame._identified == text then return frame.info end
                frame._identified = text
                local c = frame.ctx or {}
                local ok, info = pcall(RC.IdentifyImport, RC, text, { raidName = c.raidName })
                if not ok then
                    RC:DebugPrint("Import window: identify failed: " .. tostring(info), "profile")
                    info = { kind = "unknown", text = text, lines = {}, ready = false,
                        title = RCL["Not recognised"],
                        problem = RCL["Readycheck could not read this text."] }
                end
                Show(info)
                return info
            end
            frame.Identify = Identify

            local editFrame = self.UI:CreateStyledEditBox(content, {
                multiLine = true, scrollable = true, scrollHeight = 110, font = 10,
                onTextChanged = function()
                    frame._textGen = (frame._textGen or 0) + 1
                    local gen = frame._textGen
                    C_Timer.After(0.2, function()
                        if frame._textGen == gen and frame:IsShown() then Identify() end
                    end)
                end,
            })
            editFrame:SetPoint("TOPLEFT", 0, -28)
            editFrame:SetPoint("RIGHT", content, "RIGHT", 0, 0)
            frame.editBox = editFrame.editBox
            frame.editBox:SetScript("OnEscapePressed", function() frame:Hide() end)

            local importBtn = self.UI:CreateStyledButton(content, RCL["Import"], 130, 26)
            importBtn:SetPoint("BOTTOMLEFT", 0, 0)
            frame.importBtn = importBtn
            importBtn:SetScript("OnClick", function()
                local c = frame.ctx or {}
                local info = Identify()
                local ok, msg, res = false, nil, nil
                if not info or info.kind == "empty" then
                    msg = RCL["No import string provided"]
                else
                    local called
                    -- the name only counts while its box is on screen
                    called, ok, msg, res = pcall(RC.ImportAny, RC, frame.editBox:GetText() or "", {
                        info = info, raidName = c.raidName,
                        name = info.wantsName and frame.nameBox:GetText() or nil,
                    })
                    if not called then
                        RC:DebugPrint("Import window: import failed: " .. tostring(ok), "profile")
                        ok, msg, res = false, RCL["the import stopped on an error - nothing further was changed"], nil
                    end
                end
                if not ok then
                    RC:Print(RCL["Import failed"] .. (msg and (" - " .. msg) or "."))
                    return
                end
                if msg then RC:Print(msg) end
                if res and res.reload then
                    frame:Hide()
                    ReloadUI()
                    -- still here a moment later: the reload did not happen
                    C_Timer.After(2, function()
                        RC:Print(RCL["The import is in, but the UI did not reload - type /reload to finish."])
                    end)
                    return
                end
                frame.editBox:SetText("")
                frame._identified = nil
                frame:Hide()
                -- (RC:ImportAny has already redrawn the open settings page)
                if c.onDone then
                    local fine, err = pcall(c.onDone, res)
                    if not fine then
                        RC:DebugPrint("Import window: onDone failed: " .. tostring(err), "profile")
                    end
                end
            end)

            local cancelBtn = self.UI:CreateStyledButton(content, RCL["Cancel"], 80, 26)
            cancelBtn:SetPoint("BOTTOMRIGHT", 0, 0)
            cancelBtn:SetScript("OnClick", function() frame:Hide() end)
            RC.UI:SkinPopup(frame, { buttons = { cancelBtn }, primary = importBtn })

            self.universalImportFrame = frame
        end

        frame.ctx = ctx
        frame.titleText:SetText(ctx.title or RCL["Import"])
        -- ZacUI's strings are passed across to it when it is loaded, so
        -- the hint only promises that when it is true.
        local zacui = type(_G.ZacUI) == "table" and type(_G.ZacUI.Import) == "table"
        frame.hint:SetText(RCL["Paste any Readycheck export: settings, a raid profile, a route, notes or a custom reminder. It is recognised by itself."]
            .. (zacui and RCL[" ZacUI strings work here too."] or ""))
        frame._identified = nil
        frame._namedFor = nil
        frame.nameBox:SetText("")
        frame.editBox:SetText("")
        frame.ShowInfo(nil)
        if not frame:IsShown() then RC.UI:PopIn(frame, 0.12) end
        frame:Raise()
        frame.editBox:SetFocus()
        return frame
    end

    -- Brings the open settings page up to date after an import (called
    -- by RC:ImportAny). An import can come from a window opened on some
    -- other page, or from ZacUI, and two kinds of page must not be left
    -- as they were drawn:
    --   a raid page (bosses, trash, route) keeps editing the tables it
    --   was drawn from, and a raid profile or a route replaces those;
    --   the notes page writes a box back when it loses focus, and would
    --   write an old note over one that just came in.
    -- Each is redrawn the way it redraws itself - the raid pages through
    -- the profile bar's own refresh (the one switching profile uses, so
    -- the tab and the scroll position stay), the notes page as a tab
    -- switch to the tab it is on. Nothing else is touched: other pages
    -- hold text that is only saved when the user says so.
    function RC:RefreshAfterImport(res)
        local frame = self.sidebarConfigFrame
        if not (frame and frame.IsShown and frame:IsShown()) then return end
        local kind = type(res) == "table" and res.kind
        if kind == "raidProfile" or kind == "route" then
            if self.RefreshSidebarProfiles then self:RefreshSidebarProfiles() end
            local page = self._raidPageRedraw
            if not (page and page.fn and page.bar and page.bar.IsVisible and page.bar:IsVisible()) then return end
            C_Timer.After(0.05, function()
                -- The page that opened the import window may have redrawn
                -- itself by now; the bar it was drawn with is gone then.
                if not page.bar:IsVisible() then return end
                RC:ClearSidebarContent(RC.sidebarConfigFrame, true)
                page.fn()
                if RC.RestoreScrollPosition then RC:RestoreScrollPosition(RC.sidebarConfigFrame) end
            end)
        elseif kind == "notes" then
            local compat = frame.compatFrame
            if compat and self.ShowSidebarBossNotes and self.SidebarState
               and self.SidebarState.currentPanel == "boss_notes" then
                self:ShowSidebarBossNotes(compat, compat.bossNotesTab or "general")
            end
        end
    end

