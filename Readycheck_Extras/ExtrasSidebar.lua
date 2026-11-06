------------------------------------------------------------------------
-- Readycheck_Extras - Changelog Sidebar Page
-- Defines RC:ShowSidebarChangelog, which renders RC.Changelog.versions
-- (see Changelog.lua) as cards. Section colors/labels come from the shared
-- RC.Changelog.sectionStyles table defined in Changelog.lua (which loads
-- first per the .toc); unknown entry types fall back to gray.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end

    function RC:ShowSidebarChangelog(frame)
        local parent = frame.scrollChild
        local yPos = -20

        local _, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Changelog"],
            RCL["Version history and recent changes  |  Discord: zac12"],
            "Interface\\Icons\\INV_Misc_Note_05")
        yPos = newY

        local popupBtn = self.UI:CreateStyledButton(parent, RCL["Open in window"], 140, 24)
        popupBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", 15, yPos)
        popupBtn:SetScript("OnClick", function()
            if RC.Changelog and RC.Changelog.Show then
                RC.Changelog:Show()
            end
        end)
        yPos = yPos - 36

        if not (self.Changelog and self.Changelog.versions and #self.Changelog.versions > 0) then
            local emptyCard = self:CreateSettingsCard(parent, yPos, RCL["Changelog"])
            local cardY = -30
            local note = self:CreateFontString(emptyCard, "OVERLAY", nil, 11)
            note:SetPoint("TOPLEFT", emptyCard, "TOPLEFT", 15, cardY)
            note:SetPoint("RIGHT", emptyCard, "RIGHT", -15, 0)
            note:SetJustifyH("LEFT")
            note:SetText(RCL["No changelog data available."])
            local _c = self:GetColor("text", "gray"); note:SetTextColor(_c.r, _c.g, _c.b, _c.a)
            cardY = cardY - 20
            emptyCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - emptyCard:GetHeight() - 15
        else
            -- Shared with the popup renderer; defined once in Changelog.lua.
            -- Changelog.lua's init is deferred until RC.db/RC.UI exist, so
            -- guard with an empty-table fallback just in case.
            local sectionStyles = (self.Changelog and self.Changelog.sectionStyles) or {}

            for _, ver in ipairs(self.Changelog.versions) do
                local titleText = "v" .. tostring(ver.version)
                if ver.date then titleText = titleText .. "  -  " .. ver.date end
                local card = self:CreateSettingsCard(parent, yPos, titleText)
                local cardY = -30

                if ver.sections then
                    for _, section in ipairs(ver.sections) do
                        local style = sectionStyles[section.type]
                        local color = style and style.color or {0.7, 0.7, 0.7}
                        local label = style and style.label or section.type

                        local sectionHeader = self:CreateFontString(card, "OVERLAY", nil, 10)
                        sectionHeader:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
                        sectionHeader:SetText(label)
                        sectionHeader:SetTextColor(color[1], color[2], color[3])
                        cardY = cardY - 15

                        for _, item in ipairs(section.items) do
                            local bullet = self:CreateFontString(card, "OVERLAY", nil, 10)
                            bullet:SetPoint("TOPLEFT", card, "TOPLEFT", 20, cardY)
                            bullet:SetText("-")
                            bullet:SetTextColor(color[1], color[2], color[3], 0.6)

                            local itemText = self:CreateFontString(card, "OVERLAY", nil, 10)
                            itemText:SetPoint("TOPLEFT", card, "TOPLEFT", 30, cardY)
                            itemText:SetPoint("RIGHT", card, "RIGHT", -15, 0)
                            itemText:SetJustifyH("LEFT")
                            itemText:SetText(item)
                            local _c = self:GetColor("text", "gray"); itemText:SetTextColor(_c.r, _c.g, _c.b, _c.a)

                            local textHeight = itemText:GetStringHeight() or 11
                            cardY = cardY - math.max(13, textHeight + 2)
                        end

                        cardY = cardY - 3
                    end
                end

                cardY = cardY - 5
                card:SetContentHeight(math.abs(cardY))
                yPos = yPos - card:GetHeight() - 15
            end
        end

        if self.UpdateSidebarScrollbar then
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
        end
    end
