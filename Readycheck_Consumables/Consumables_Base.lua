------------------------------------------------------------------------
-- Readycheck - Consumables Bar Chrome
-- Shared cosmetic helpers for the three consumable bars (consumablesHelper,
-- potionsBar, weaponsBar): frame border, accent lines, mouseover fade.
-- Loads first in the Consumables folder: it only creates RC._chInit and
-- defines methods on RC. RC.db does not exist yet, so nothing here may
-- read it at load time - the fade getters defer that into a closure.
------------------------------------------------------------------------

-- Taint-safe API locals (fallbacks on RC.Compat, built in Core;
-- never write _G - a written Blizzard global taints its readers)
local RCC = _G.Readycheck
local RC = RCC
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local GetItemSpell = GetItemSpell or (RCC and RCC.Compat and RCC.Compat.GetItemSpell)
local UnitAura = UnitAura or (RCC and RCC.Compat and RCC.Compat.UnitAura)

-- One fade updater per bar rather than a shared parameterised one: each
-- reads a different db table, and ApplyMouseoverFade takes a getter that
-- is re-evaluated on every hover, so options changes need no re-attach.
-- fadeIn / fadeOut are the bar's own fade lengths (Consumables_Style).
do
    local RC = _G.Readycheck
    if RC then
        function RC:UpdateConsumablesBarMouseoverFade()
            local f = self.consumablesHelper and self.consumablesHelper.frame
            if f and self.ApplyMouseoverFade then
                self:ApplyMouseoverFade(f, function()
                    local d = self.db and self.db.consumablesHelper
                    if not d then return nil end
                    local fi, fo = RC.BarStyle.FadeTimes("consumablesHelper")
                    return { enabled = d.mouseoverFade, alpha = d.mouseoverFadeAlpha or 0.15, fadeIn = fi, fadeOut = fo }
                end)
            end
        end

        function RC:UpdatePotionsBarMouseoverFade()
            local f = self.potionsBar and self.potionsBar.frame
            if f and self.ApplyMouseoverFade then
                self:ApplyMouseoverFade(f, function()
                    local d = self.db and self.db.potionsBar
                    if not d then return nil end
                    local fi, fo = RC.BarStyle.FadeTimes("potionsBar")
                    return { enabled = d.mouseoverFade, alpha = d.mouseoverFadeAlpha or 0.15, fadeIn = fi, fadeOut = fo }
                end)
            end
        end

        function RC:UpdateWeaponsBarMouseoverFade()
            local f = self.weaponsBar and self.weaponsBar.frame
            if f and self.ApplyMouseoverFade then
                self:ApplyMouseoverFade(f, function()
                    local d = self.db and self.db.weaponsBar
                    if not d then return nil end
                    local fi, fo = RC.BarStyle.FadeTimes("weaponsBar")
                    return { enabled = d.mouseoverFade, alpha = d.mouseoverFadeAlpha or 0.15, fadeIn = fi, fadeOut = fo }
                end)
            end
        end
    end
end

-- Every other Consumables file appends its init closure to this queue.
-- Consumables_Bootstrap drains it once RC.db exists.
local WRF = _G.Readycheck
if WRF then
    WRF._chInit = WRF._chInit or {}
end

function RC:ApplyBarAccent(frame, accentNS, borderCol, shouldShowBg)
    frame.accentLine = {}
    local accentCol = RC:GetColor(accentNS, "accentLine") or borderCol
    -- Each entry is {anchorA, anchorB, sizeSetter}. The 2px inset keeps the
    -- accent inside the 1px frame border; the setter names which axis is
    -- fixed at 1px, since the other axis is pinned by the two anchors.
    local sides = {
        top    = { { "TOPLEFT", 2, -2 },    { "TOPRIGHT", -2, -2 },    "SetHeight" },
        bottom = { { "BOTTOMLEFT", 2, 2 },  { "BOTTOMRIGHT", -2, 2 },  "SetHeight" },
        left   = { { "TOPLEFT", 2, -2 },    { "BOTTOMLEFT", 2, 2 },    "SetWidth" },
        right  = { { "TOPRIGHT", -2, -2 },  { "BOTTOMRIGHT", -2, 2 },  "SetWidth" },
    }
    for name, s in pairs(sides) do
        local t = frame:CreateTexture(nil, "OVERLAY")
        -- Half alpha of the configured accent: the line reads as a hairline
        -- highlight against the border rather than a second border.
        t:SetColorTexture(accentCol.r, accentCol.g, accentCol.b, (accentCol.a or 1) * 0.5)
        t:SetPoint(s[1][1], s[1][2], s[1][3])
        t:SetPoint(s[2][1], s[2][2], s[2][3])
        t[s[3]](t, 1)
        if not shouldShowBg then t:Hide() end
        frame.accentLine[name] = t
    end
end

-- After a bar's background is switched on or off: the accent hairlines
-- follow it (they were left showing over a bar with no background), and
-- the screen clamp is measured again, so with the chrome hidden the
-- buttons themselves can go right up to the screen edge straight away -
-- not only after the bar next changes size.
function RC:SyncBarChrome(frame, shouldShowBg)
    if not frame then return end
    frame.__rcChromeHidden = not shouldShowBg
    for _, t in pairs(frame.accentLine or {}) do
        if shouldShowBg then t:Show() else t:Hide() end
    end
    if RC.Position and RC.Position.ScheduleClamp then RC.Position.ScheduleClamp(frame) end
end

function RC:ApplyBarChrome(frame, borderCol, shouldShowBg, accentNS)
    frame.border = RC.UI:CreateSimpleBorder(frame)
    RC.UI:UpdateBorderColor(frame.border, borderCol)
    if not shouldShowBg then
        if frame.border.top    then frame.border.top:Hide()    end
        if frame.border.bottom then frame.border.bottom:Hide() end
        if frame.border.left   then frame.border.left:Hide()   end
        if frame.border.right  then frame.border.right:Hide()  end
    end
    self:ApplyBarAccent(frame, accentNS or "weaponBar", borderCol, shouldShowBg)
end
