------------------------------------------------------------------------
-- Readycheck - Consumables Checker: Window Lifecycle
-- Owns show/hide/toggle for the checker frame, its auto-open/close hooks
-- at the Auction House and mailbox, the materials-search popup, and the
-- AH search glue (Auctionator/aux/vanilla fallback).
------------------------------------------------------------------------
local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local table_insert, table_remove, table_sort = table.insert, table.remove, table.sort
local string_format = string.format
local GetTime = GetTime
local GetItemCount = GetItemCount or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemCount)
local GetItemInfo = GetItemInfo or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemInfo)
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local WRF = _G.Readycheck
if not WRF then return end
WRF._cckInit = WRF._cckInit or {}
WRF._cck = WRF._cck or {}
WRF._cckInit[#WRF._cckInit + 1] = function()
    local RC = _G.Readycheck
    local _cck = WRF._cck
    local GetAccentGold, GetCardBg, GetHeaderBg = _cck.GetAccentGold, _cck.GetCardBg, _cck.GetHeaderBg
    local BuildPopupShell = _cck.BuildPopupShell
    function RC:ToggleConsumablesChecker()
        if not self.raidConsumables then
            self:Print(RCL["Error: Consumables data not loaded. Please reload your UI."])
            return
        end

        if not self.consumablesChecker.frame then
            self:CreateConsumablesCheckerFrame()
            RC.consumablesChecker._populated = false
            self:PopulateConsumablesChecker()
        end

        if self.consumablesChecker.frame:IsShown() then
            self.consumablesChecker.wasManuallyShown = false
            if RC.UI.PopOut then
                RC.UI:PopOut(self.consumablesChecker.frame, 0.1)
            else
                self.consumablesChecker.frame:Hide()
            end
        else
            self.consumablesChecker.wasManuallyShown = true
            self.consumablesChecker.currentContext = "manual"
            self:ApplyConsumablesCheckerPosition()
            RC.consumablesChecker._populated = false
            self:PopulateConsumablesChecker()
            self.consumablesChecker.frame:Show()
            self.consumablesChecker.frame:Raise()
        end
    end

    local ahFrame = CreateFrame("Frame")
    ahFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
    ahFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
    ahFrame:SetScript("OnEvent", function(self, event)
        if event == "AUCTION_HOUSE_SHOW" then
            if not RC.db or not RC.db.consumablesChecker or not RC.db.consumablesChecker.enabled then return end

            if RC.db.consumablesChecker.reportOnAHOpen and RC.PrintConsumablesReport then
                C_Timer.After(0.3, function()
                    RC:PrintConsumablesReport()
                end)
            end

            if RC.db.consumablesChecker.autoOpenAtAH == false then return end

            if not RC.consumablesChecker.frame then
                RC:CreateConsumablesCheckerFrame()
            end
            RC.consumablesChecker.wasManuallyShown = false
            RC.consumablesChecker.currentContext = "ah"
            RC:ApplyConsumablesCheckerPosition()
            RC.consumablesChecker.frame:Show()
            RC.consumablesChecker.frame:Raise()
            if not RC.consumablesChecker._populated then
                RC.consumablesChecker._populated = false
                RC:PopulateConsumablesChecker()
            else
                RC:InvalidateCheckerColorCache()
                RC:UpdateConsumablesCheckerDisplay()
            end
        elseif event == "AUCTION_HOUSE_CLOSED" then
            if RC.db.consumablesChecker.autoCloseAtAH == false then return end
            if RC.consumablesChecker.frame and not RC.consumablesChecker.wasManuallyShown then
                RC.consumablesChecker.frame:Hide()
            end
        end
    end)

    local mailFrame = CreateFrame("Frame")
    mailFrame:RegisterEvent("MAIL_SHOW")
    mailFrame:RegisterEvent("MAIL_CLOSED")

    -- Guarded 0.5s ticker scoped to the mailbox being open: started on
    -- MAIL_SHOW, cancelled on MAIL_CLOSED or as soon as MailFrame is seen
    -- gone, so nothing runs while no mailbox is up.
    local mailCloseTicker

    local function StopMailCloseCheck()
        if mailCloseTicker then
            mailCloseTicker:Cancel()
            mailCloseTicker = nil
        end
    end

    local function StartMailCloseCheck()
        if mailCloseTicker then return end
        local fn = function()
            if not MailFrame or not MailFrame:IsShown() then
                RC.consumablesChecker.mailboxOpen = false
                StopMailCloseCheck()
                if RC.db and RC.db.consumablesChecker and RC.db.consumablesChecker.autoCloseAtMailbox == false then return end
                if RC.consumablesChecker.frame and not RC.consumablesChecker.wasManuallyShown then
                    RC.consumablesChecker.frame:Hide()
                end
            end
        end
        if RC.Profiler and RC.Profiler.TrackTicker then
            mailCloseTicker = RC.Profiler:TrackTicker("ConsumablesChecker:MailCloseCheck", 0.5, fn)
        else
            mailCloseTicker = C_Timer.NewTicker(0.5, fn)
        end
    end

    mailFrame:SetScript("OnEvent", function(self, event)
        if event == "MAIL_SHOW" then
            RC.consumablesChecker.mailboxOpen = true
            StartMailCloseCheck()
            if not RC.db or not RC.db.consumablesChecker or not RC.db.consumablesChecker.enabled then return end
            if RC.db.consumablesChecker.autoOpenAtMailbox == false then return end

            if not RC.consumablesChecker.frame then
                RC:CreateConsumablesCheckerFrame()
            end
            RC.consumablesChecker.wasManuallyShown = false
            RC.consumablesChecker.currentContext = "mailbox"
            RC:ApplyConsumablesCheckerPosition()
            RC.consumablesChecker.frame:Show()
            RC.consumablesChecker.frame:Raise()
            if not RC.consumablesChecker._populated then
                RC.consumablesChecker._populated = false
                RC:PopulateConsumablesChecker()
            else
                RC:InvalidateCheckerColorCache()
                RC:UpdateConsumablesCheckerDisplay()
            end
        elseif event == "MAIL_CLOSED" then
            RC.consumablesChecker.mailboxOpen = false
            StopMailCloseCheck()
            if RC.db.consumablesChecker.autoCloseAtMailbox == false then return end
            if RC.consumablesChecker.frame and not RC.consumablesChecker.wasManuallyShown then
                RC.consumablesChecker.frame:Hide()
            end
        end
    end)

    local function OnMailSidePanelChange()
        if RC.consumablesChecker.currentContext == "mailbox"
        and RC.consumablesChecker.frame
        and RC.consumablesChecker.frame:IsShown()
        and RC.db and RC.db.consumablesChecker
        and RC.db.consumablesChecker.anchorToMailbox ~= false then
            RC:ApplyConsumablesCheckerPosition()
        end
    end

    C_Timer.After(0, function()
        if OpenMailFrame then
            hooksecurefunc(OpenMailFrame, "Show", OnMailSidePanelChange)
            hooksecurefunc(OpenMailFrame, "Hide", OnMailSidePanelChange)
        end
        if SendMailFrame then
            hooksecurefunc(SendMailFrame, "Show", OnMailSidePanelChange)
            hooksecurefunc(SendMailFrame, "Hide", OnMailSidePanelChange)
        end
    end)

    do
        -- Sole refresh cadence for the open checker window; bag counts are
        -- rescanned here, not on BAG_UPDATE, so the high-frequency bag/
        -- cooldown events never trigger a rebuild directly. The ticker
        -- exists only while the window is shown: the frame's OnShow hook
        -- (Checker_Popup.lua) starts it, OnHide (or seeing the frame gone)
        -- cancels it.
        local displayTicker
        local fn = function()
            if RC.consumablesChecker.frame and RC.consumablesChecker.frame:IsShown() then
                if not UnitAffectingCombat("player") then
                    RC:UpdateConsumablesCheckerDisplay()
                end
            else
                RC:StopCheckerDisplayTicker()
            end
        end
        function RC:StopCheckerDisplayTicker()
            if displayTicker then
                displayTicker:Cancel()
                displayTicker = nil
            end
        end
        function RC:StartCheckerDisplayTicker()
            if displayTicker then return end
            if RC.Profiler and RC.Profiler.TrackTicker then
                displayTicker = RC.Profiler:TrackTicker("ConsumablesChecker:DisplayUpdate", 2, fn)
            else
                displayTicker = C_Timer.NewTicker(2, fn)
            end
        end
        -- The frame can already be on screen when this module initialises
        -- (e.g. after a settings reload); catch up here.
        if RC.consumablesChecker.frame and RC.consumablesChecker.frame:IsShown() then
            RC:StartCheckerDisplayTicker()
        end
    end

    -- itemId: the consumable itself. It gets its own row above its
    -- materials - Jujus, R.O.I.D.S. and the rest sell on the auction house
    -- ready-made, and this popup used to offer only what they are made of.
    function RC:ShowMaterialsSearchPopup(itemData, anchor, itemId)
        if not self.materialsSearchPopup then
            -- Shared flat popup shell from Checker_Base.lua (30px title
            -- bar, gold rule, chromeless X, ESC, PopIn/PopOut).
            local popup = BuildPopupShell("WRMaterialsSearchPopup", RCL["Search on Auction House"], 236, 100)
            popup.buttons = {}
            self.materialsSearchPopup = popup
        end

        local popup = self.materialsSearchPopup

        popup.titleText:SetText(RCL["Search on Auction House"])

        local PADDING = 8
        local BTN_H = 24
        local BTN_W = 220
        local yOff = -(30 + PADDING)

        -- The rows: the item itself (when known), then each material.
        local entries = {}
        if itemId then
            local own = (GetItemInfo(itemId)) or itemData.name
            own = own and own:gsub("%s*%(MH%)", ""):gsub("%s*%(OH%)", ""):gsub("%s+$", "")
            entries[#entries + 1] = { name = own, itemId = itemId, isItem = true }
        end
        for _, mat in ipairs(itemData.materials) do entries[#entries + 1] = mat end

        -- Buttons are pooled by index and reused across opens; only the
        -- label text/color and the click target change per open.
        for i, mat in ipairs(entries) do
            local btn = popup.buttons[i]
            if not btn then
                btn = RC.UI:CreateStyledButton(popup, "", BTN_W, BTN_H)
                btn:RegisterForClicks("LeftButtonUp")

                local label = self:CreateFontString(btn, "OVERLAY", nil, 10)
                label:SetPoint("LEFT", btn, "LEFT", 8, 0)
                label:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
                label:SetJustifyH("LEFT")
                btn.label = label

                popup.buttons[i] = btn
            end
            local label = btn.label
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", popup, "TOPLEFT", PADDING, yOff)
            btn:Show()

            local bagCount = (not mat.isItem) and mat.itemId and GetItemCount(mat.itemId, false, false) or nil
            local countText = ""
            local stockFull   = RC:GetColor("consumables", "stockFull")
            local stockMed    = RC:GetColor("consumables", "stockMedium")
            local stockEmpty  = RC:GetColor("consumables", "stockEmpty")
            local countColor  = stockFull
            if bagCount then
                if bagCount >= mat.qty then
                    countText = " (" .. bagCount .. ")"
                    countColor = stockFull
                elseif bagCount > 0 then
                    countText = " (" .. bagCount .. "/" .. mat.qty .. ")"
                    countColor = stockMed
                else
                    countText = " (0/" .. mat.qty .. ")"
                    countColor = stockEmpty
                end
            end
            if mat.isItem then
                label:SetText(mat.name)
            else
                label:SetText(mat.qty .. "x  " .. mat.name .. countText)
            end
            if bagCount and bagCount < mat.qty then
                label:SetTextColor(countColor.r, countColor.g, countColor.b, 1)
            else
                local normC = RC:GetColor("text", "normal")
                label:SetTextColor(normC.r, normC.g, normC.b, 1)
            end

            local matItemId = mat.itemId
            local matSearchName = mat.ahSearchName or mat.name
            -- An ahSearchName override is a deliberately broad term (e.g.
            -- "Bijou" for the whole Hakkari set); only unoverridden names
            -- are safe to search exactly.
            local matExact = (mat.ahSearchName == nil)
            btn:SetScript("OnClick", function()
                popup:Close()
                RC:OpenAuctionHouseForItem(matItemId, matSearchName, matExact)
            end)

            yOff = yOff - BTN_H - 4
        end

        for i = #entries + 1, #popup.buttons do
            popup.buttons[i]:Hide()
        end

        local totalH = 30 + PADDING + (#entries * (BTN_H + 4)) + PADDING
        popup:SetSize(BTN_W + PADDING * 2, totalH)

        popup:ClearAllPoints()
        if anchor then
            popup:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 6, 0)
        else
            popup:SetPoint("CENTER")
        end
        popup:Open()
    end

    ------------------------------------------------------------------
    -- AH search glue.
    --
    -- Two failure modes this replaces:
    --
    --  * Substring searches. "Elixir of the Mongoose" also matches
    --    "Recipe: Elixir of the Mongoose", and the recipe sorts above the
    --    consumable, so the row you clicked hands you the wrong listing.
    --    Searches are now exact by default. Entries whose ahSearchName is
    --    a deliberately broad term ("Bijou" covering every Hakkari bijou)
    --    pass exact = false and keep substring behaviour.
    --
    --  * Blank result pages while shopping. The old path fired two
    --    unguarded C_Timer.After closures per click with no throttle check.
    --    A buyout puts the server in a query cooldown, so a click landing
    --    right after a purchase reset the browse frame and then had its
    --    query dropped - an empty list with nothing to re-query it. Rapid
    --    clicking stacked those closures on top of each other. There is now
    --    a single pending search (latest click wins) that waits on
    --    CanSendAuctionQuery before touching the browse frame at all.
    ------------------------------------------------------------------

    local searchTimer

    local function CancelPendingSearch()
        if searchTimer then
            searchTimer:Cancel()
            searchTimer = nil
        end
    end

    -- Classic Era gained an exact-match toggle on the browse frame, but the
    -- global it lives under has moved between builds. When it is found we
    -- drive Blizzard's own search so paging, filters and the disabled state
    -- of the search button all stay consistent; when it is not, we issue the
    -- query ourselves and pass exactMatch directly.
    local function FindExactMatchToggle()
        local cb = _G.BrowseExactMatchCheckButton
                or _G.ExactMatchCheckButton
                or (_G.AuctionFrameBrowse and _G.AuctionFrameBrowse.ExactMatchCheckButton)
        if type(cb) == "table" and type(cb.SetChecked) == "function" and type(cb.GetChecked) == "function" then
            return cb
        end
        return nil
    end

    local MAX_QUERY_ATTEMPTS = 30   -- 30 x 0.2s = ~6s of throttle patience

    local function SendBrowseQuery(itemName, exact, attempt)
        searchTimer = nil

        -- AH closed under us (or the player walked away) - drop it silently
        -- rather than poking a hidden frame.
        if not AuctionFrame or not AuctionFrame:IsShown() then return end

        if CanSendAuctionQuery and not CanSendAuctionQuery() then
            if attempt >= MAX_QUERY_ATTEMPTS then
                RC:Print(RCL["Auction House is still busy - search cancelled, try that item again."])
                return
            end
            searchTimer = C_Timer.NewTimer(0.2, function()
                SendBrowseQuery(itemName, exact, attempt + 1)
            end)
            return
        end

        if BrowseName then
            BrowseName:SetText(itemName)
            BrowseName:ClearFocus()
        end
        if AuctionFrameBrowse then
            AuctionFrameBrowse.page = 0
        end

        local toggle = FindExactMatchToggle()
        if toggle then
            toggle:SetChecked(exact and true or false)
            if BrowseSearchButton then
                BrowseSearchButton:Click()
                return
            end
        end

        -- Classic signature:
        -- QueryAuctionItems(name, minLevel, maxLevel, page, usable, rarity,
        --                   getAll, exactMatch, filterData)
        local ok = pcall(QueryAuctionItems, itemName, nil, nil, 0, nil, nil, false, exact and true or false)
        if not ok then
            ok = pcall(QueryAuctionItems, itemName, nil, nil, 0, nil, nil, false)
        end
        if not ok and BrowseSearchButton then
            BrowseSearchButton:Click()
        end
    end

    -- exact defaults to true. Callers holding a deliberately partial search
    -- term (see ahSearchName in DB_Consumables) pass false.
    function RC:OpenAuctionHouseForItem(itemId, itemName, exact)
        if not itemName and not itemId then
            self:Print(RCL["Error: No item name or ID provided"])
            return
        end

        if not AuctionFrame or not AuctionFrame:IsShown() then
            self:Print(RCL["Please open the Auction House first!"])
            return
        end

        if exact == nil then exact = true end

        -- Prefer the client's own name for the id: the display name in the
        -- checker can carry suffixes or be a stale hand-written string, and
        -- an exact search against a near-miss name returns nothing at all.
        if exact and itemId then
            local realName = GetItemInfo(itemId)
            if realName then itemName = realName end
        end
        if not itemName and itemId then
            itemName = GetItemInfo(itemId) or tostring(itemId)
        end

        CancelPendingSearch()

        -- ZacUI's auction window, when it is the one on screen: search in
        -- it rather than behind it. Driving Blizzard's hidden browse frame
        -- from here put the results under ZacUI's previous search, which
        -- then re-ran that old search over them - the item looked unlisted
        -- while it was on the auction house.
        local zui = _G.ZacUIAuction
        if type(zui) == "table" and type(zui.IsOpen) == "function" and zui.IsOpen()
                and type(zui.Search) == "function" then
            if zui.Search(itemName, exact) then return end
        end

        if Auctionator and Auctionator.API and Auctionator.API.v1 then
            local api = Auctionator.API.v1
            if exact and api.MultiSearchExact then
                api.MultiSearchExact("Readycheck", {itemName})
                return
            elseif api.MultiSearch then
                api.MultiSearch("Readycheck", {itemName})
                return
            end
        elseif aux and aux.scan and aux.scan.start and itemId and exact then
            aux.scan.start({itemId = itemId})
            return
        end

        self:VanillaAHSearch(itemName, exact)
    end

    function RC:VanillaAHSearch(itemName, exact)
        if not AuctionFrame or not AuctionFrame:IsShown() then
            self:Print(RCL["Please open the Auction House first!"])
            return
        end

        CancelPendingSearch()

        -- Only switch tabs when we are not already on Browse. Re-clicking the
        -- active tab tears down and rebuilds the results list, which is the
        -- other way the page went blank mid-shop.
        if not (AuctionFrameBrowse and AuctionFrameBrowse:IsShown()) and AuctionFrameTab1 then
            AuctionFrameTab1:Click()
        end

        if exact == nil then exact = true end
        SendBrowseQuery(itemName, exact, 0)
    end

    -- A closing AH must not leave a retry ticking against a dead frame.
    ahFrame:HookScript("OnEvent", function(_, event)
        if event == "AUCTION_HOUSE_CLOSED" then
            CancelPendingSearch()
        end
    end)

    C_Timer.After(2.0, function()
        if RC and RC.InitializeConsumablesCheckerDefaults then
            RC:InitializeConsumablesCheckerDefaults()
        end
    end)
end
