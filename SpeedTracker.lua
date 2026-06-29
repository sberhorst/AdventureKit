--[[
    SpeedTracker v3.0.0  (embedded in AdventureKit)
    Author: morphe#11766

    WoW 12.x target. No legacy API.

    Combat taint: GetUnitSpeed() arithmetic is blocked mid-combat by
    Blizzard's taint system. pcall wraps the division; the last known
    value is held while tainted so the display freezes rather than errors.

    v3.0.0:
      - Frame auto-sizes to text width; no dead space left/right
      - showLabel toggle: hides "Speed" sublabel, collapses frame to 1 line
      - Draggable, lockable, scalable — same controls as before
]]

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------
local ST_VERSION    = "3.0.0"
local ST_UPDATE     = 0.15
local ST_BASE_SPEED = 7.0
local ST_PAD_H      = 6    -- horizontal padding each side of text
local ST_PAD_V      = 4    -- vertical padding top/bottom

------------------------------------------------------------------------
-- Defaults
------------------------------------------------------------------------
local ST_DEFAULTS = {
    x          = 10,
    y          = -10,
    locked     = false,
    scale      = 1.0,
    hidden     = false,
    showLabel  = true,   -- show "Speed" sublabel beneath the %
}

local stDB  -- assigned on ADDON_LOADED

local function ST_ApplyDefaults()
    if not stDB then return end
    for k, v in pairs(ST_DEFAULTS) do
        if stDB[k] == nil then stDB[k] = v end
    end
end

------------------------------------------------------------------------
-- Speed calculation
------------------------------------------------------------------------
local lastSpeedText = "0%"

local function GetSpeedText()
    local ok, pct = pcall(function()
        local current = GetUnitSpeed("player")
        if not current or current == 0 then return "0%" end
        return string.format("%.0f%%", (current / ST_BASE_SPEED) * 100)
    end)
    if ok and pct then lastSpeedText = pct end
    return lastSpeedText
end

------------------------------------------------------------------------
-- Frame — no fixed size; auto-fits to content
------------------------------------------------------------------------
local tracker = CreateFrame("Frame", "SpeedTrackerFrame", UIParent)
tracker:SetFrameStrata("MEDIUM")
tracker:SetClampedToScreen(true)
tracker:SetMovable(true)
tracker:EnableMouse(true)
tracker:RegisterForDrag("LeftButton")

-- Subtle dark backdrop; no border
local stBG = tracker:CreateTexture(nil, "BACKGROUND")
stBG:SetAllPoints()
stBG:SetColorTexture(0, 0, 0, 0.5)

-- Main speed percentage text
local stSpeedText = tracker:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
stSpeedText:SetTextColor(0.2, 1, 0.4, 1)
stSpeedText:SetJustifyH("CENTER")

-- "Speed" sublabel
local stSubLabel = tracker:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
stSubLabel:SetText("Speed")
stSubLabel:SetTextColor(0.5, 0.5, 0.5, 1)
stSubLabel:SetJustifyH("CENTER")

------------------------------------------------------------------------
-- Layout: recompute frame size to hug the text
------------------------------------------------------------------------
local function ST_UpdateLayout()
    if not stDB then return end

    local showLbl = stDB.showLabel ~= false  -- default true

    -- Measure text widths
    stSpeedText:SetText(lastSpeedText)
    local tw = stSpeedText:GetStringWidth()
    local lw = showLbl and stSubLabel:GetStringWidth() or 0
    local contentW = math.max(tw, lw) + ST_PAD_H * 2

    -- Height: 1 or 2 rows
    local speedH  = stSpeedText:GetStringHeight()
    local labelH  = showLbl and (stSubLabel:GetStringHeight() + 2) or 0
    local contentH = speedH + labelH + ST_PAD_V * 2

    tracker:SetSize(math.max(contentW, 30), math.max(contentH, 16))

    -- Anchor text inside frame
    stSpeedText:ClearAllPoints()
    stSpeedText:SetPoint("TOP", tracker, "TOP", 0, -ST_PAD_V)

    stSubLabel:ClearAllPoints()
    if showLbl then
        stSubLabel:SetPoint("TOP", stSpeedText, "BOTTOM", 0, -2)
        stSubLabel:Show()
    else
        stSubLabel:Hide()
    end
end

------------------------------------------------------------------------
-- Update ticker
------------------------------------------------------------------------
local stTicker = CreateFrame("Frame")
local stElapsed = 0
stTicker:SetScript("OnUpdate", function(_, dt)
    stElapsed = stElapsed + dt
    if stElapsed < ST_UPDATE then return end
    stElapsed = 0
    local txt = GetSpeedText()
    stSpeedText:SetText(txt)
    ST_UpdateLayout()
end)

------------------------------------------------------------------------
-- Drag
------------------------------------------------------------------------
tracker:SetScript("OnDragStart", function(self)
    if stDB and not stDB.locked then self:StartMoving() end
end)

tracker:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if stDB then
        local _, _, _, x, y = self:GetPoint()
        if x and y then stDB.x = x; stDB.y = y end
    end
end)

tracker:SetScript("OnMouseDown", function(self, btn)
    if btn == "RightButton" and stDB then
        stDB.locked = not (stDB.locked == true)
        print("|cff00ccff[SpeedTracker]|r " .. (stDB.locked and "Locked." or "Unlocked."))
    end
end)

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------
SpeedTrackerAPI = {}

function SpeedTrackerAPI.SetLocked(val)
    if stDB then stDB.locked = val end
end

function SpeedTrackerAPI.SetScale(val)
    if type(val) ~= "number" then return end
    val = math.max(0.1, math.min(val, 10.0))
    if stDB then stDB.scale = val end
    tracker:SetScale(val)
end

function SpeedTrackerAPI.SetHidden(val)
    if stDB then stDB.hidden = val end
    if val then tracker:Hide() else tracker:Show() end
end

function SpeedTrackerAPI.SetShowLabel(val)
    if stDB then stDB.showLabel = val end
    ST_UpdateLayout()
end

function SpeedTrackerAPI.ResetPosition()
    if stDB then stDB.x = ST_DEFAULTS.x; stDB.y = ST_DEFAULTS.y end
    tracker:ClearAllPoints()
    tracker:SetPoint("TOPLEFT", UIParent, "TOPLEFT", ST_DEFAULTS.x, ST_DEFAULTS.y)
end

function SpeedTrackerAPI.GetDB()       return stDB end
function SpeedTrackerAPI.GetDefaults() return ST_DEFAULTS end
function SpeedTrackerAPI.GetVersion()  return ST_VERSION end

------------------------------------------------------------------------
-- Slash: /speed
------------------------------------------------------------------------
SLASH_SPEEDTRACKER1 = "/speed"
SlashCmdList["SPEEDTRACKER"] = function(input)
    local cmd = ((input or ""):lower():match("^%s*(%S*)%s*$") or "")
    if cmd == "lock"  then
        if stDB then
            stDB.locked = not (stDB.locked == true)
            print("|cff00ccff[SpeedTracker]|r " .. (stDB.locked and "Locked." or "Unlocked."))
        end
    elseif cmd == "reset"  then SpeedTrackerAPI.ResetPosition(); print("|cff00ccff[SpeedTracker]|r Position reset.")
    elseif cmd == "hide"   then SpeedTrackerAPI.SetHidden(true);  print("|cff00ccff[SpeedTracker]|r Hidden.")
    elseif cmd == "show"   then SpeedTrackerAPI.SetHidden(false); print("|cff00ccff[SpeedTracker]|r Visible.")
    elseif cmd == "label"  then
        if stDB then
            stDB.showLabel = not (stDB.showLabel == true)
            ST_UpdateLayout()
            print("|cff00ccff[SpeedTracker]|r Label " .. (stDB.showLabel and "shown." or "hidden."))
        end
    else
        print("|cff00ccff[SpeedTracker]|r Commands: lock | reset | hide | show | label")
    end
end

------------------------------------------------------------------------
-- Init on ADDON_LOADED
------------------------------------------------------------------------
local stInitFrame = CreateFrame("Frame")
stInitFrame:RegisterEvent("ADDON_LOADED")
stInitFrame:SetScript("OnEvent", function(self, event, arg1)
    if arg1 ~= "AdventureKit" then return end

    AdventureKitDB = AdventureKitDB or {}
    AdventureKitDB.SpeedTracker = AdventureKitDB.SpeedTracker or {}
    stDB = AdventureKitDB.SpeedTracker
    ST_ApplyDefaults()

    tracker:SetScale(stDB.scale or 1.0)
    tracker:ClearAllPoints()
    tracker:SetPoint("TOPLEFT", UIParent, "TOPLEFT", stDB.x, stDB.y)
    ST_UpdateLayout()

    if stDB.hidden then tracker:Hide() else tracker:Show() end

    self:UnregisterEvent("ADDON_LOADED")
end)
