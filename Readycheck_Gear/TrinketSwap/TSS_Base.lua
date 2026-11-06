------------------------------------------------------------------------
-- Readycheck - Trinket Swap Fade Settings
-- The trinket-specific fade settings glue (which db table the toggle
-- button reads, and the "apply this alpha to every bar" sync helper).
-- The generic mouseover-fade machinery itself lives in core, in
-- Readycheck\UI\Framework\UIF_Anim.lua.
-- Not trinket-swap logic itself; the RC._tssInit bootstrap table that
-- every other TSS_*.lua file queues into is also seeded here.
------------------------------------------------------------------------
local ipairs = ipairs
local C_Container = C_Container

do
    local RC = _G.Readycheck
    if RC then
        local DEFAULT_FADE_ALPHA = 0.15

        -- Whether Classic Era exposes C_Container.GetItemCooldown is
        -- client-build dependent - the Consumables module assumes it does
        -- not and keeps its own bag-scan cache. This helper sidesteps the
        -- question: use the API when the running client has it, otherwise
        -- fall back to core's equipped-slot + bag-scan shim
        -- (RC:GetItemCooldown, Systems/CooldownManager.lua). Both return
        -- (start, duration) with 0, 0 meaning "not on cooldown".
        -- Defined here because TSS_Base.lua is the first file in the .toc,
        -- so every TrinketSwap and Manager call site can reach it.
        function RC:GetItemCooldownSafe(itemId)
            if not itemId then return 0, 0 end
            if C_Container and C_Container.GetItemCooldown then
                local start, duration = C_Container.GetItemCooldown(itemId)
                return start or 0, duration or 0
            end
            if self.GetItemCooldown then
                return self:GetItemCooldown(itemId)
            end
            return 0, 0
        end

        -- The generic mouseover-fade machinery (_FadeFrameAlpha,
        -- AttachMouseoverFade, AttachContainerMouseoverFade,
        -- ApplyMouseoverFade and the container hover poll) now lives in
        -- core: Readycheck\UI\Framework\UIF_Anim.lua. It is still hung
        -- off RC, so the call sites below and in Readycheck_Consumables
        -- are unchanged - but the consumables bars no longer lose their
        -- fade when this addon is switched off.

        RC._GetTrinketFadeSettings = function()
            local d = RC.db and RC.db.trinketSwap
            if not d then return nil end
            return { enabled = d.mouseoverFade, alpha = d.mouseoverFadeAlpha or DEFAULT_FADE_ALPHA }
        end

        function RC:UpdateTrinketButtonMouseoverFade()
            if self.trinketToggleButton then
                self:ApplyMouseoverFade(self.trinketToggleButton, RC._GetTrinketFadeSettings)
            end
        end

        function RC:SyncBarFadeAllSettings(sourceKey)
            if not (self.db and self.db[sourceKey]) then return nil end
            local source  = self.db[sourceKey]
            local enabled = source.mouseoverFade and true or false
            local alpha   = source.mouseoverFadeAlpha or DEFAULT_FADE_ALPHA
            if alpha < 0 then alpha = 0 end
            if alpha > 1 then alpha = 1 end

            for _, key in ipairs({"consumablesHelper", "potionsBar", "weaponsBar"}) do
                local target = self.db[key]
                if target then
                    target.mouseoverFade      = enabled
                    target.mouseoverFadeAlpha = alpha
                end
            end

            for _, frameField in ipairs({"consumablesHelper", "potionsBar", "weaponsBar"}) do
                local container = self[frameField]
                local frame     = container and container.frame
                if frame then frame._containerFadeOver = nil end
            end

            if self.UpdateConsumablesBarMouseoverFade then self:UpdateConsumablesBarMouseoverFade() end
            if self.UpdatePotionsBarMouseoverFade     then self:UpdatePotionsBarMouseoverFade()     end
            if self.UpdateWeaponsBarMouseoverFade     then self:UpdateWeaponsBarMouseoverFade()     end

            if self.SaveConfigurationToProfile then
                self:SaveConfigurationToProfile()
            end

            return math.floor(alpha * 100 + 0.5), enabled
        end

    end
end

-- Queue consumed once by TSS_Bootstrap.lua's SafeInitialize; each
-- TSS_*.lua file appends its own init function here.
local WRF = _G.Readycheck
if WRF then
    WRF._tssInit = WRF._tssInit or {}
end
