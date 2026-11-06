------------------------------------------------------------------------
-- Readycheck - Route from Warcraft Logs
-- The game cannot open a browser, so this window hands over the route
-- page's address ready to copy, a Copy my character button (the gear
-- sets, gear and consumables the page lets you pick from), and a Paste
-- Route button for what the page gives back. The page reads public
-- reports through the Readycheck relay, so nobody signs in, needs an
-- API key or a file.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not (RC and RC.UI and RC.CreateSettingsCard) then return end
RC._srr = RC._srr or {}
local _srr = RC._srr

local RM = {}

local FLAT = "Interface\\Buttons\\WHITE8X8"
local function C(cat, key) return RC:GetColor(cat, key) end

-- The Readycheck Routes page (GitHub Pages, repository
-- Zac175/readycheck-routes). If it is ever emptied, the window says the
-- page is not online instead of handing over a dead link.
RC.ROUTE_TOOL_URL = RC.ROUTE_TOOL_URL or "https://zac175.github.io/readycheck-routes/"

local logsWin
local function BuildLogsWindow()
    local border, winBg, hdrBg, acGold, headerText = C("ui", "borderNormal"), C("ui", "windowBackground"),
        C("ui", "headerBackground"), C("ui", "accentGold"), C("ui", "headerText")
    local f = CreateFrame("Frame", "ReadycheckRouteFromLogs", UIParent, "BackdropTemplate")
    f:SetSize(460, 330)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1 })
    f:SetBackdropColor(winBg.r, winBg.g, winBg.b, 0.98)
    f:SetBackdropBorderColor(border.r, border.g, border.b, border.a or 1)
    f:Hide()
    if RC.UI.RegisterEscapeClose then RC.UI:RegisterEscapeClose("ReadycheckRouteFromLogs") end

    -- the title bar every Readycheck window wears (gradient and stepped
    -- gold rule from ApplyHeaderArt), like the Import Route window
    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetHeight(30)
    titleBar:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
    titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
    local hb = titleBar:CreateTexture(nil, "BACKGROUND")
    hb:SetAllPoints()
    hb:SetTexture(FLAT)
    hb:SetVertexColor(hdrBg.r, hdrBg.g, hdrBg.b, hdrBg.a or 1)
    local hd = titleBar:CreateTexture(nil, "ARTWORK")
    hd:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 0, 0)
    hd:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
    hd:SetHeight(1)
    hd:SetTexture(FLAT)
    hd:SetVertexColor(acGold.r, acGold.g, acGold.b, 0.6)
    if RC.UI.ApplyHeaderArt then
        hd:Hide()
        RC.UI:ApplyHeaderArt(titleBar, { fill = hb, stepX = 160 })
    end
    local titleIcon = RC.UI.AddTitleIcon and RC.UI:AddTitleIcon(titleBar, 16, 8)
    local title = RC:CreateFontString(titleBar, "OVERLAY", nil, 15, "OUTLINE")
    if titleIcon then
        title:SetPoint("LEFT", titleIcon, "RIGHT", 8, 0)
    else
        title:SetPoint("LEFT", titleBar, "LEFT", 12, 0)
    end
    title:SetText(RCL["Route from Warcraft Logs"])
    title:SetTextColor(headerText.r, headerText.g, headerText.b)
    local close = RC.UI:CreateXCloseButton(titleBar, 22, function() f:Hide() end)
    close:SetPoint("RIGHT", titleBar, "RIGHT", -5, 0)

    local norm, gray, gold = C("text", "normal"), C("text", "gray"), C("text", "gold")
    local function Line(text, y)
        local fs = RC:CreateFontString(f, "OVERLAY", nil, 11)
        fs:SetPoint("TOPLEFT", f, "TOPLEFT", 16, y)
        fs:SetPoint("RIGHT", f, "RIGHT", -16, 0)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        fs:SetText(text)
        fs:SetTextColor(norm.r, norm.g, norm.b)
        return fs
    end
    Line(RCL["1. Copy this link (Ctrl+C) and open it in your web browser:"], -44)

    local box = RC.UI:CreateStyledEditBox(f, { height = 24, font = 11, maxLetters = 300 })
    box:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -64)
    box:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -64)
    local eb = box.editBox
    -- the address can be selected and copied but not changed
    eb:SetScript("OnTextChanged", function(e, user)
        if user and RC.ROUTE_TOOL_URL ~= "" and e:GetText() ~= RC.ROUTE_TOOL_URL then
            e:SetText(RC.ROUTE_TOOL_URL)
            e:HighlightText()
        end
    end)
    eb:SetScript("OnEditFocusGained", function(e) e:HighlightText() end)
    eb:SetScript("OnMouseUp", function(e) e:SetFocus() e:HighlightText() end)
    eb:SetScript("OnEscapePressed", function(e) e:ClearFocus() f:Hide() end)
    eb:SetScript("OnEnterPressed", function(e) e:ClearFocus() end)
    f.urlBox = eb

    local l2 = Line(RCL["2. Paste your report's link there and click Copy on the raid (no sign-in needed)."], -98)
    local l3 = Line(RCL["3. Come back, click Paste Route and press Ctrl+V. Gear and reminders on your old steps are kept wherever they still fit."], -134)
    l3:SetTextColor(norm.r, norm.g, norm.b)
    local l4 = Line(RCL["To pick gear sets, trinkets and consumables on the page: click Copy my character, press Ctrl+C, and paste the text into the page's Your character box."], -176)
    l4:SetTextColor(gray.r, gray.g, gray.b)

    local cbox = RC.UI:CreateStyledEditBox(f, { height = 24, font = 11, maxLetters = 60000 })
    cbox:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -210)
    cbox:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -210)
    local ceb = cbox.editBox
    -- the text can be selected and copied but not changed
    ceb:SetScript("OnTextChanged", function(e, user)
        if user and f.charText and e:GetText() ~= f.charText then
            e:SetText(f.charText)
            e:HighlightText()
        end
    end)
    ceb:SetScript("OnEditFocusGained", function(e) e:HighlightText() end)
    ceb:SetScript("OnMouseUp", function(e) e:SetFocus() e:HighlightText() end)
    ceb:SetScript("OnEscapePressed", function(e) e:ClearFocus() end)
    ceb:SetScript("OnEnterPressed", function(e) e:ClearFocus() end)
    f.charBox = ceb

    local copyChar = RC.UI:CreateStyledButton(f, RCL["Copy my character"], 140, 24)
    copyChar:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 12)
    copyChar:SetScript("OnClick", function()
        local RR = RC.RaidRoute
        -- (not "RR and RR:CharacterString()": an and-chain keeps only the
        -- first of the returned values, and the counts would be lost)
        local text, n, ng, nu
        if RR and RR.CharacterString then text, n, ng, nu = RR:CharacterString() end
        if not text or ((n or 0) == 0 and (ng or 0) == 0) then
            f.charText = nil
            f.charBox:SetText(RCL["Nothing to copy - make a gear set on the Gear Sets page (or in ItemRack), or carry some gear, first."])
            return
        end
        f.charText = text
        f.charBox:SetText(text)
        f.charBox:SetFocus()
        f.charBox:HighlightText()
        f.note:SetText(RCL["Copied text holds "] .. (n or 0) .. RCL[" gear set(s), "] .. (ng or 0)
            .. RCL[" item(s) and "] .. (nu or 0) .. RCL[" consumable(s). Press Ctrl+C now, then paste it on the page."])
    end)
    f.note = RC:CreateFontString(f, "OVERLAY", nil, 10)
    f.note:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 44)
    f.note:SetTextColor(gray.r, gray.g, gray.b)

    local paste = RC.UI:CreateStyledButton(f, RCL["Paste Route"], 120, 24)
    paste:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 12)
    if paste.SetActive then paste:SetActive(true) end
    paste:SetScript("OnClick", function()
        f:Hide()
        if _srr.ShowRouteSharePopup then _srr.ShowRouteSharePopup("import", f.raid, f.afterImport) end
    end)
    local done = RC.UI:CreateStyledButton(f, RCL["Close"], 80, 24)
    done:SetPoint("RIGHT", paste, "LEFT", -8, 0)
    done:SetScript("OnClick", function() f:Hide() end)
    f:SetScript("OnShow", function(self)
        self:Raise()
        if RC.ROUTE_TOOL_URL == "" then
            self.urlBox:SetText(RCL["The route page is not online yet - check back after the next update."])
            return
        end
        self.urlBox:SetText(RC.ROUTE_TOOL_URL)
        self.urlBox:SetFocus()
        self.urlBox:HighlightText()
    end)
    f._gold = gold
    return f
end

function RM:ShowFromLogs(raid, afterImport)
    logsWin = logsWin or BuildLogsWindow()
    logsWin.raid, logsWin.afterImport = raid, afterImport
    logsWin.note:SetText(raid and (RCL["The route goes to "] .. raid .. ".") or "")
    logsWin:Hide()
    logsWin:Show()
end

_srr.ShowFromLogs = function(raid, afterImport) RM:ShowFromLogs(raid, afterImport) end
