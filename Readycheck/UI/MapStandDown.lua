------------------------------------------------------------------------
-- Readycheck - The map comes first
-- Readycheck's on-screen frames sit at HIGH strata so they stay above
-- the action bars and unit frames; the world map window sits there
-- too, so a reminder that happens to be where the map opens draws over
-- the map (2026-10-31, Zac: "the readycheck buff stuff overlaps stuff
-- on this new map"). Raising the map is not an option - its canvas is
-- a child that does not follow the frame's level, and a map frame above
-- its own canvas swallows every click. So while the world map is open,
-- every Readycheck frame that overlaps it fades out, and comes back as
-- it was when the map closes. Frames clear of the map are left alone.
--
-- Which frames: everything placed by RC.Position (RC.Position.bound)
-- and everything the frame mover knows (RC.UIMover.frames) - bars,
-- reminders, trackers, the stats bar, the world-buff mini (which sits
-- at DIALOG strata, so strata is no test: the two lists are on-screen
-- frames by definition, the config window is in neither). A frame that appears
-- while the map is open is caught by the same 0.25s tick the mover
-- uses to keep frames hidden, which also puts the alpha back if the
-- frame's own code touched it.
--
-- Setting: RC.db.hideUnderMap (off by default - Zac keeps the world-buff
-- timers over the map and asked where they had gone; General page).
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end

local faded = {}        -- frame -> the alpha it had
local ticker
local mapHooked = false

local function Enabled()
    return RC.db and RC.db.hideUnderMap == true
end

local function Overlaps(frame, map)
    local l, r, t, b = frame:GetLeft(), frame:GetRight(), frame:GetTop(), frame:GetBottom()
    local ml, mr, mt, mb = map:GetLeft(), map:GetRight(), map:GetTop(), map:GetBottom()
    if not (l and r and t and b and ml and mr and mt and mb) then return false end
    -- (both in UIParent units once each frame's own scale is applied)
    local s, ms = frame:GetEffectiveScale(), map:GetEffectiveScale()
    l, r, t, b = l * s, r * s, t * s, b * s
    ml, mr, mt, mb = ml * ms, mr * ms, mt * ms, mb * ms
    return l < mr and r > ml and b < mt and t > mb
end

-- the frames that can stand down: a set, so one frame known to both lists is one entry
local function Candidates()
    local set = {}
    local P = RC.Position
    if P and P.bound then
        for frame in pairs(P.bound) do set[frame] = true end
    end
    local UM = RC.UIMover
    if UM and UM.frames then
        for _, data in pairs(UM.frames) do
            if data.frame then set[data.frame] = true end
        end
    end
    return set
end

local function Restore()
    for frame, alpha in pairs(faded) do
        if frame.SetAlpha then frame:SetAlpha(alpha) end
    end
    wipe(faded)
end

local function Tick()
    local map = _G.WorldMapFrame
    if not (map and map:IsShown()) or not Enabled() then
        Restore()
        if ticker then ticker:Cancel(); ticker = nil end
        return
    end
    for frame in pairs(Candidates()) do
        if faded[frame] == nil and frame.IsShown and frame:IsShown() and Overlaps(frame, map) then
            faded[frame] = frame:GetAlpha()
            frame:SetAlpha(0)
        elseif faded[frame] ~= nil and frame:GetAlpha() ~= 0 and frame:IsShown() then
            frame:SetAlpha(0)       -- (its own code brought it back: not while the map is up)
        end
    end
end

local function Start()
    if not Enabled() then return end
    Tick()
    if not ticker then
        ticker = RC.Profiler:TrackTicker("MapStandDown", 0.25, Tick)
    end
end

local function HookMap()
    if mapHooked then return true end
    local map = _G.WorldMapFrame
    if not map then return false end
    mapHooked = true
    map:HookScript("OnShow", Start)
    map:HookScript("OnHide", function()
        Restore()
        if ticker then ticker:Cancel(); ticker = nil end
    end)
    if map:IsShown() then Start() end
    return true
end

-- the General page's tick box turns it off mid-session too
function RC:ApplyMapStandDown()
    if Enabled() then
        if HookMap() and _G.WorldMapFrame:IsShown() then Start() end
    else
        Restore()
        if ticker then ticker:Cancel(); ticker = nil end
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" and name ~= "Blizzard_WorldMap" then return end
    if HookMap() then self:UnregisterEvent("ADDON_LOADED") end
end)
