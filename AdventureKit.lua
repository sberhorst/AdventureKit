--[[
    AdventureKit v2.0.0
    Author: morphe#11766

    Features:
      1. Auto-repair all gear when interacting with a repair vendor
      2. Auto-sell all grey (poor quality) items that are NOT quest items
      3. Alert on dungeon/raid entry: missing flask, food, pet, and raid-wide buffs
      4. Warn when any equipped gear slot is below 50% durability
      5. Persistent HUD showing Flask / Food status — glows red when missing
      6. Embedded SpeedTracker movement speed display (loaded via SpeedTracker.lua)

    v1.6.0 — Hardening pass:
      - All db accesses guarded against nil (pre-ADDON_LOADED race)
      - muteInCombat now actually suppresses alerts
      - AutoSellGreyItems: fixed sellPrice nil crash (GetItemInfo cache miss)
      - CheckGearDurability: fixed GetInventorySlotInfo nil concat crash
      - UNIT_DIED / UNIT_AURA: db nil guard added
      - OnDragStop (HUD): nil-safe coordinate save
      - RunInstanceAlerts: wrapped in SafeCall at all call sites
      - C_Timer callbacks: re-check db validity inside closure
]]

------------------------------------------------------------------------
-- Addon identity
------------------------------------------------------------------------
local ADDON_NAME    = "AdventureKit"
local ADDON_VERSION = "2.3.1"
local PREFIX        = "|cff00ccff[AdventureKit]|r"

------------------------------------------------------------------------
-- SavedVariables defaults
------------------------------------------------------------------------
local DEFAULTS = {
    autoRepair          = true,
    useGuildRepair      = false,
    autoSellGrey        = true,
    durabilityThreshold = 50,
    durabilityCheck     = true,
    alertInDungeon      = true,   -- fire entry alerts in dungeons/M+
    alertInRaid         = true,   -- fire entry alerts in raids
    alertInDelve        = true,   -- fire entry alerts in delves
    alertFlask          = true,
    alertFood           = true,
    alertPet            = true,
    alertPetDeath       = true,
    alertRaidBuffs      = true,
    showBuffHUD         = true,
    buffHUDAlwaysShow   = false,
    hudLocked           = false,
    hudScale            = 1.5,
    hudX                = 200,
    hudY                = -210,
    muteInCombat        = true,
    -- Cursor reticle
    cursorEnabled       = true,
    cursorSize          = 32,       -- ring radius in pixels
    cursorAlpha         = 0.85,
    cursorR             = 0.91,     -- gold: R
    cursorG             = 0.78,     -- gold: G
    cursorB             = 0.29,     -- gold: B
    cursorHideInCombat  = false,    -- hide reticle during combat
    cursorInstanceOnly  = false,    -- only show in dungeons/raids/delves
}

local db  -- assigned on ADDON_LOADED

local function ApplyDefaults()
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
end

------------------------------------------------------------------------
-- Utility helpers
------------------------------------------------------------------------
local function Print(msg)
    print(PREFIX .. " " .. tostring(msg))
end

local function SafeCall(fn, ...)
    local ok, err = pcall(fn, ...)
    -- Uncomment next line to surface errors during development:
    -- if not ok then print(PREFIX .. " ERR: " .. tostring(err)) end
    return ok
end

-- Guard: returns true if db is ready and we are NOT in combat when
-- muteInCombat is enabled.  Use before any chat-alert path.
local function AlertsAllowed()
    if not db then return false end
    if db.muteInCombat and InCombatLockdown() then return false end
    return true
end

-- Guard: returns true if alerts are enabled for the given instance type.
-- instanceType is the second return value from IsInInstance():
--   "party"    = dungeon (including M+)
--   "raid"     = raid
--   "scenario" = delve / scenario
local function AlertsEnabledForType(instanceType)
    if not db then return false end
    if instanceType == "party"    then return db.alertInDungeon == true end
    if instanceType == "raid"     then return db.alertInRaid    == true end
    if instanceType == "scenario" then return db.alertInDelve   == true end
    return false
end

------------------------------------------------------------------------
-- FEATURE 1: Auto-Repair
------------------------------------------------------------------------
local function AutoRepair()
    if not db or not db.autoRepair then return end
    -- RepairAllItems is a protected function; cannot call in combat
    if InCombatLockdown() then return end
    if not CanMerchantRepair() then return end

    local cost, possible = GetRepairAllCost()
    if not possible or not cost or cost == 0 then return end

    local guildRepaired = false
    if db.useGuildRepair then
        local guildMoney = GetGuildBankMoney and GetGuildBankMoney() or 0
        if guildMoney >= cost then
            SafeCall(RepairAllItems, true)
            guildRepaired = true
            Print("Repaired all gear using |cffffff00Guild Bank|r gold. Cost: " .. GetCoinTextureString(cost))
        end
    end

    if not guildRepaired then
        local playerMoney = GetMoney()
        if playerMoney >= cost then
            SafeCall(RepairAllItems, false)
            Print("Repaired all gear. Cost: " .. GetCoinTextureString(cost))
        else
            Print("|cffff4444Not enough gold to repair. Need " .. GetCoinTextureString(cost) ..
                  ", have " .. GetCoinTextureString(playerMoney) .. "|r")
        end
    end
end

------------------------------------------------------------------------
-- FEATURE 2: Auto-Sell Grey Items (non-quest)
------------------------------------------------------------------------
local function AutoSellGreyItems()
    if not db or not db.autoSellGrey then return end

    local totalValue = 0
    local soldCount  = 0
    local bagSlots   = NUM_BAG_SLOTS or 4   -- safe fallback if global not yet set

    for bag = 0, bagSlots do
        local slots = 0
        SafeCall(function()
            slots = C_Container and C_Container.GetContainerNumSlots(bag)
                    or GetContainerNumSlots(bag) or 0
        end)

        for slot = 1, slots do
            local quality, noValue, itemID, itemCount

            SafeCall(function()
                if C_Container then
                    local info = C_Container.GetContainerItemInfo(bag, slot)
                    if info then
                        quality   = info.quality
                        noValue   = info.hasNoValue
                        itemID    = info.itemID
                        itemCount = info.stackCount or 1
                    end
                else
                    local _, cnt, _, q, _, _, _, _, nv, id = GetContainerItemInfo(bag, slot)
                    quality   = q
                    noValue   = nv
                    itemID    = id
                    itemCount = cnt or 1
                end
            end)

            if quality == 0 and not noValue and itemID then
                local isQuestItem = false
                SafeCall(function()
                    if C_Container then
                        local qi = C_Container.GetContainerItemQuestInfo(bag, slot)
                        if qi and (qi.isActive or qi.isQuestItem) then
                            isQuestItem = true
                        end
                    else
                        local itemClass = select(12, GetItemInfo(itemID))
                        if itemClass == 12 then isQuestItem = true end
                    end
                end)

                if not isQuestItem then
                    -- FIX: GetItemInfo may return nil if item not cached yet.
                    -- sellPrice is the 11th return value.
                    local sellPrice = 0
                    SafeCall(function()
                        local sp = select(11, GetItemInfo(itemID))
                        if type(sp) == "number" then sellPrice = sp end
                    end)

                    if C_Container then
                        SafeCall(C_Container.UseContainerItem, bag, slot)
                    else
                        SafeCall(UseContainerItem, bag, slot)
                    end
                    totalValue = totalValue + (sellPrice * itemCount)
                    soldCount  = soldCount + 1
                end
            end
        end
    end

    if soldCount > 0 then
        Print("Sold " .. soldCount .. " grey item(s) for " .. GetCoinTextureString(totalValue))
    end
end

------------------------------------------------------------------------
-- FEATURE 3: Instance Entry Alerts
------------------------------------------------------------------------
local FLASK_BUFF_IDS = {
    432021, 432022, 432023, 432024, 432025,
}

local RAID_BUFF_MAP = {
    ["DRUID"]       = { { 1126,   "Mark of the Wild" } },
    ["WARRIOR"]     = { { 6673,   "Battle Shout" } },
    ["DEATHKNIGHT"] = { { 57330,  "Horn of Winter" } },
    ["MAGE"]        = { { 1459,   "Arcane Intellect" } },
    ["PRIEST"]      = { { 21562,  "Power Word: Fortitude" } },
    ["PALADIN"]     = { { 19740,  "Blessing of Might" }, { 25898, "Greater Blessing of Kings" } },
    ["MONK"]        = { { 116781, "Legacy of the Emperor" } },
    ["EVOKER"]      = { { 364342, "Blessing of the Bronze" } },
}

-- Classes with permanent combat pets in WoW 12.x.
-- HUNTER: BM and Survival specs require a pet. MM cannot use Call Pet (Lone Wolf).
--   The addon alerts for all Hunters; the "MM Hunters excluded" note appears in the UI.
-- DEATHKNIGHT: Only Unholy has a permanent ghoul. Blood/Frost DKs do not.
--   We alert for all DKs; the sublabel in the UI clarifies the spec requirement.
-- MAGE: Frost Mage has a permanent Water Elemental combat pet.
--   Fire and Arcane Mages have no permanent pet; they will see a false alert.
--   We cannot detect spec from UnitClass() — the UI sublabel explains this.
local PET_CLASSES = {
    ["HUNTER"]      = true,
    ["WARLOCK"]     = true,
    ["DEATHKNIGHT"] = true,
    ["MAGE"]        = true,
}

------------------------------------------------------------------------
-- Buff scanning helper
--
-- WoW 12.x (The War Within): C_UnitAuras.GetBuffDataByIndex is the
-- correct API for reading player buffs. Returns a table with .name
-- and .spellId fields, or nil when the slot is empty / out of range.
------------------------------------------------------------------------

-- Returns (name, spellID) for buff slot i, or (nil, nil) if empty.
local function GetBuffInfo(unit, i)
    local ok, data = pcall(C_UnitAuras.GetBuffDataByIndex, unit, i)
    if ok and data then
        return data.name, data.spellId
    end
    return nil, nil
end

local function HasFlask()
    for i = 1, 40 do
        local name, spellID = GetBuffInfo("player", i)
        if not name then break end
        -- Name-based check (catches any flask regardless of tier)
        if name:find("Flask") then return true end
        -- Spell ID check for known TWW flasks
        if spellID then
            for _, id in ipairs(FLASK_BUFF_IDS) do
                if spellID == id then return true end
            end
        end
    end
    return false
end

local FOOD_BUFF_NAMES = {
    ["Well Fed"]             = true,
    ["Exquisitely Seasoned"] = true,
    ["Hearty Meal"]          = true,
    ["Banquet"]              = true,
}

local function HasFood()
    for i = 1, 40 do
        local name = GetBuffInfo("player", i)
        if not name then break end
        if FOOD_BUFF_NAMES[name] then return true end
        if name:find("Well Fed") or name:find("Fed") or
           name:find("Feast")    or name:find("Meal") or
           name:find("Dish") then
            return true
        end
    end
    return false
end

-- Cache the pet-class result after first successful UnitClass call.
-- UnitClass("player") can return nil during early loading screens.
local _cachedIsPetClass = nil

local function IsPetClass()
    if _cachedIsPetClass ~= nil then return _cachedIsPetClass end
    local ok, result = pcall(function()
        local _, cf = UnitClass("player")
        return cf
    end)
    if not ok or not result then
        return false  -- not cached; will retry next call
    end
    _cachedIsPetClass = (PET_CLASSES[result] == true)
    return _cachedIsPetClass
end

local function PetStatus()
    -- UnitExists("pet") returns true briefly before the pet fully loads
    -- after a zone transition, causing false "no pet" alerts.
    -- UnitHealth("pet") > 0 is the authoritative signal from the server
    -- that the pet is alive and active. Zero health = dead or not loaded.
    local exists = false
    SafeCall(function() exists = UnitExists("pet") == true end)
    if not exists then return "none" end

    -- Pet exists: check health to confirm it's alive and fully loaded
    local health = 0
    SafeCall(function() health = UnitHealth("pet") or 0 end)
    if health <= 0 then
        -- Could be dead OR still loading — treat as not-yet-ready; don't alert
        local dead = false
        SafeCall(function() dead = UnitIsDead("pet") == true end)
        return dead and "dead" or "none"
    end

    return "alive"
end

local function CheckRaidBuffs()
    if not AlertsAllowed() then return end
    -- pcall-wrap UnitClass: can return nil during loading screen transitions
    local classFile
    SafeCall(function()
        local _, cf = UnitClass("player")
        classFile = cf
    end)
    if not classFile then return end
    local buffs = RAID_BUFF_MAP[classFile]
    if not buffs then return end  -- class has no raid buff responsibility

    -- Determine group size for scanning
    local numMembers = GetNumGroupMembers()
    local groupPrefix = IsInRaid() and "raid" or "party"

    for _, buffInfo in ipairs(buffs) do
        local spellID, label = buffInfo[1], buffInfo[2]

        -- Check if the buff exists on ANY group member (including player).
        -- Checking the group rather than self is the correct signal that
        -- you have actually applied the buff to the raid/party.
        local found = false
        local unitsToCheck = { "player" }
        for m = 1, math.max(numMembers, 1) do
            table.insert(unitsToCheck, groupPrefix .. m)
        end

        for _, unit in ipairs(unitsToCheck) do
            if UnitExists(unit) then
                for i = 1, 40 do
                    local name, id = GetBuffInfo(unit, i)
                    if not name then break end
                    if id == spellID then found = true; break end
                end
            end
            if found then break end
        end

        if not found then
            Print("|cffff9900[Raid Buff]|r Apply |cffffff00" .. label ..
                  "|r to the raid — your buff is not active on the group!")
        end
    end
end

-- Maps instanceType to a readable label for chat alerts
local INSTANCE_LABELS = {
    ["party"]    = "Dungeon",
    ["raid"]     = "Raid",
    ["scenario"] = "Delve",
}

local function RunInstanceAlerts()
    if not db then return end

    local inInstance, instanceType = IsInInstance()
    if not inInstance then return end
    if not AlertsEnabledForType(instanceType) then return end

    local typeLabel = INSTANCE_LABELS[instanceType] or "Instance"

    -- Flask/food/buffs at 3s — should be active before zoning in.
    C_Timer.After(3, function()
        if not db then return end
        if not AlertsAllowed() then return end
        local stillIn, iType = IsInInstance()
        if not stillIn or not AlertsEnabledForType(iType) then return end

        local issues = {}
        if db.alertFlask and not HasFlask() then
            table.insert(issues, "|cffff4444No Flask active!|r")
        end
        if db.alertFood and not HasFood() then
            table.insert(issues, "|cffff4444No Food buff (Well Fed) active!|r")
        end
        if #issues > 0 then
            Print(typeLabel .. " entry check:")
            for _, issue in ipairs(issues) do print("  " .. issue) end
        end
        if db.alertRaidBuffs then
            SafeCall(CheckRaidBuffs)
        end
    end)

    -- Pet at 6s — needs time to fully register after zone transition.
    C_Timer.After(6, function()
        if not db then return end
        if not AlertsAllowed() then return end
        if not db.alertPet then return end
        if not IsPetClass() then return end
        local stillIn, iType = IsInInstance()
        if not stillIn or not AlertsEnabledForType(iType) then return end

        local ps = PetStatus()
        if ps == "none" then
            Print(typeLabel .. " entry check:")
            print("  |cffff4444No pet summoned!|r")
        elseif ps == "dead" then
            Print(typeLabel .. " entry check:")
            print("  |cffff4444Pet is dead — resurrect before pulling!|r")
        end
    end)
end

------------------------------------------------------------------------
-- FEATURE 4: Durability Warning
------------------------------------------------------------------------
local GEAR_SLOTS = {
    INVSLOT_HEAD, INVSLOT_NECK, INVSLOT_SHOULDER, INVSLOT_CHEST,
    INVSLOT_WAIST, INVSLOT_LEGS, INVSLOT_FEET, INVSLOT_WRIST,
    INVSLOT_HAND, INVSLOT_FINGER1, INVSLOT_FINGER2,
    INVSLOT_TRINKET1, INVSLOT_TRINKET2,
    INVSLOT_BACK, INVSLOT_MAINHAND, INVSLOT_OFFHAND, INVSLOT_RANGED,
}

local durabilityWarned = false
local petGraceActive  = false   -- true during post-zone pet load window

local function CheckGearDurability()
    if not db or not db.durabilityCheck then return end

    local threshold = db.durabilityThreshold or 50
    local lowSlots  = {}

    for _, slotID in ipairs(GEAR_SLOTS) do
        if slotID then   -- INVSLOT_* constants are nil for slots that don't exist on this character
            local current, max = GetInventoryItemDurability(slotID)
            if current and max and max > 0 then
                local pct = (current / max) * 100
                if pct < threshold then
                    -- FIX: GetInventorySlotInfo can return nil; guard the concat
                    local display
                    SafeCall(function()
                        display = GetInventoryItemLink("player", slotID)
                    end)
                    display = display or ("Slot " .. tostring(slotID))
                    table.insert(lowSlots, display .. string.format(" (%.0f%%)", pct))
                end
            end
        end
    end

    if #lowSlots > 0 then
        Print("|cffff4444DURABILITY WARNING:|r Items below " .. threshold .. "% durability:")
        for _, s in ipairs(lowSlots) do
            print("  " .. s)
        end
    end
end

------------------------------------------------------------------------
-- FEATURE 5: Flask / Food / Pet Alert HUD
--
-- Free-floating alert rows — no background frame.
-- MISSING: row shows, icon flashes red.
-- OK:      row hides entirely (no green state).
-- When all alerts are satisfied the entire HUD hides.
-- Draggable, lockable, scalable. Scale saved to db.hudScale.
------------------------------------------------------------------------

local ICON_FLASK = "Interface\\Icons\\inv_alchemy_flask_souldrinker"
local ICON_FOOD  = "Interface\\Icons\\inv_misc_food_meat_cooked_01"
local ICON_PET   = "Interface\\Icons\\ability_hunter_beastcall"

local HUD_ICON_SIZE  = 36
local HUD_LABEL_OFSX = 44    -- label starts right of icon + gap
local HUD_ROW_H      = 40    -- row height to fit larger icon
local HUD_PAD        = 2     -- outer padding
local HUD_LABEL_W    = 110   -- label column width

local FLASH_ON  = 0.5
local FLASH_OFF = 0.35

------------------------------------------------------------------------
-- HUD outer frame
------------------------------------------------------------------------
local hudFrame = CreateFrame("Frame", "AdventureKitHUD", UIParent)
hudFrame:SetFrameStrata("MEDIUM")
hudFrame:SetClampedToScreen(true)
hudFrame:SetMovable(true)
hudFrame:EnableMouse(true)
hudFrame:RegisterForDrag("LeftButton")
hudFrame:Hide()

hudFrame:SetScript("OnDragStart", function(self)
    if db and not db.hudLocked then self:StartMoving() end
end)

hudFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if db then
        local _, _, _, x, y = self:GetPoint()
        if x and y then db.hudX = x; db.hudY = y end
    end
end)

------------------------------------------------------------------------
-- Build one alert row
------------------------------------------------------------------------
local function MakeAlertRow(parent, iconTexture)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(HUD_ROW_H)
    row:SetPoint("LEFT",  parent, "LEFT",  HUD_PAD, 0)
    row:SetPoint("RIGHT", parent, "RIGHT", -HUD_PAD, 0)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(HUD_ICON_SIZE, HUD_ICON_SIZE)
    icon:SetPoint("LEFT", row, "LEFT", 0, 0)
    icon:SetTexture(iconTexture)
    row.icon = icon

    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    lbl:SetPoint("LEFT",  row, "LEFT", HUD_LABEL_OFSX, 0)
    lbl:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    lbl:SetJustifyH("LEFT")
    lbl:SetTextColor(1, 0.25, 0.25, 1)
    row.lbl = lbl

    row.flashTimer = 0
    row.flashState = true
    row.isMissing  = false

    return row
end

-- Rows are children of a content frame so we can stack them dynamically
local hudContent = CreateFrame("Frame", nil, hudFrame)
hudContent:SetPoint("TOPLEFT",     hudFrame, "TOPLEFT",     0, 0)
hudContent:SetPoint("BOTTOMRIGHT", hudFrame, "BOTTOMRIGHT", 0, 0)

local rowFlask = MakeAlertRow(hudContent, ICON_FLASK)
local rowFood  = MakeAlertRow(hudContent, ICON_FOOD)
local rowPet   = MakeAlertRow(hudContent, ICON_PET)

local ALL_ROWS = { rowFlask, rowFood, rowPet }

------------------------------------------------------------------------
-- Restack visible rows top-to-bottom and resize frame to fit
------------------------------------------------------------------------
local function HUD_Restack()
    local visibleRows = {}
    for _, row in ipairs(ALL_ROWS) do
        if row:IsShown() then
            table.insert(visibleRows, row)
        end
    end

    if #visibleRows == 0 then
        hudFrame:Hide()
        return
    end

    local totalH = HUD_PAD * 2
    for i, row in ipairs(visibleRows) do
        row:ClearAllPoints()
        row:SetPoint("LEFT",  hudContent, "LEFT",  HUD_PAD, 0)
        row:SetPoint("RIGHT", hudContent, "RIGHT", -HUD_PAD, 0)
        local yOff = -(HUD_PAD + (i - 1) * HUD_ROW_H)
        row:SetPoint("TOP", hudContent, "TOP", 0, yOff)
        totalH = totalH + HUD_ROW_H
    end

    local w = HUD_PAD * 2 + HUD_LABEL_OFSX + HUD_LABEL_W
    hudFrame:SetSize(w, totalH)
    hudFrame:Show()
end

------------------------------------------------------------------------
-- Set a row's state: show+flash if missing, hide if OK
------------------------------------------------------------------------
local function SetRowState(row, isMissing, missingText)
    if isMissing then
        row.isMissing  = true
        row.flashTimer = 0
        row.flashState = true
        row.lbl:SetText(missingText)
        row.icon:SetAlpha(1)
        row.lbl:SetAlpha(1)
        row:Show()
    else
        row.isMissing = false
        row:Hide()
    end
end

------------------------------------------------------------------------
-- Flash ticker
------------------------------------------------------------------------
local hudTicker = CreateFrame("Frame")
hudTicker:SetScript("OnUpdate", function(_, dt)
    for _, row in ipairs(ALL_ROWS) do
        if row.isMissing and row:IsShown() then
            row.flashTimer = row.flashTimer + dt
            local cycle = row.flashState and FLASH_ON or FLASH_OFF
            if row.flashTimer >= cycle then
                row.flashTimer = 0
                row.flashState = not row.flashState
                local a = row.flashState and 1 or 0
                row.icon:SetAlpha(a)
                row.lbl:SetAlpha(a)
            end
        end
    end
end)

------------------------------------------------------------------------
-- Public scale setter (called from options panel and ADDON_LOADED)
------------------------------------------------------------------------
local function HUD_SetScale(val)
    if type(val) ~= "number" then return end
    val = math.max(0.5, math.min(val, 3.0))
    if db then db.hudScale = val end
    hudFrame:SetScale(val)
end

------------------------------------------------------------------------
-- Master refresh
------------------------------------------------------------------------
local function RefreshBuffHUD()
    if not db then return end
    if not db.showBuffHUD then hudFrame:Hide(); return end

    local inInstance, iType = IsInInstance()
    local shouldShow = db.buffHUDAlwaysShow or
                       (inInstance and AlertsEnabledForType(iType))
    if not shouldShow then hudFrame:Hide(); return end

    local flaskOK = HasFlask()
    local foodOK  = HasFood()
    local petOK   = (not IsPetClass()) or (PetStatus() == "alive")

    -- Respect the per-alert toggle: if the user disabled an alert,
    -- treat it as OK (hide the row) regardless of actual buff status.
    if db.alertFlask then
        SetRowState(rowFlask, not flaskOK, "No Flask!")
    else
        rowFlask:Hide(); rowFlask.isMissing = false
    end

    if db.alertFood then
        SetRowState(rowFood, not foodOK, "No Food!")
    else
        rowFood:Hide(); rowFood.isMissing = false
    end

    -- Pet row: only show for pet classes with alert enabled,
    -- and not during the post-zone grace period.
    if db.alertPet and IsPetClass() and not petGraceActive then
        SetRowState(rowPet, not petOK, "No Pet!")
    else
        rowPet:Hide()
        rowPet.isMissing = false
    end

    HUD_Restack()
end

------------------------------------------------------------------------
-- FEATURE 6: Cursor Reticle
--
-- Classic FPS reticle: outer ring + gapped crosshair + center dot.
-- Follows the mouse every frame via OnUpdate + GetCursorPosition().
--
-- KEY DESIGN RULE: WoW has no DestroyLine() API. Line objects created
-- with CreateLine() cannot be removed. Therefore ALL line objects are
-- created ONCE at load time and REUSED forever. Color/size changes call
-- ApplyReticleStyle() which updates existing objects in-place.
-- RebuildReticle() is now just ApplyReticleStyle() — no new objects.
------------------------------------------------------------------------

local RING_SEGMENTS = 32

local reticleFrame = CreateFrame("Frame", "AdventureKitReticle", UIParent)
reticleFrame:SetFrameStrata("TOOLTIP")
reticleFrame:SetSize(200, 200)  -- large enough to contain all line geometry
reticleFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
reticleFrame:Hide()

-- Create ALL line objects exactly once
local ringLines = {}
for i = 1, RING_SEGMENTS do
    local ln = reticleFrame:CreateLine(nil, "OVERLAY")
    ln:SetThickness(1.5)
    ringLines[i] = ln
end

local lineTop    = reticleFrame:CreateLine(nil, "OVERLAY")
local lineBottom = reticleFrame:CreateLine(nil, "OVERLAY")
local lineLeft   = reticleFrame:CreateLine(nil, "OVERLAY")
local lineRight  = reticleFrame:CreateLine(nil, "OVERLAY")
lineTop:SetThickness(1.5)
lineBottom:SetThickness(1.5)
lineLeft:SetThickness(1.5)
lineRight:SetThickness(1.5)

local dotTex = reticleFrame:CreateTexture(nil, "OVERLAY")
dotTex:SetSize(3, 3)
dotTex:SetPoint("CENTER", reticleFrame, "CENTER", 0, 0)

------------------------------------------------------------------------
-- Apply color + recompute geometry — called on init and setting changes
------------------------------------------------------------------------
local function ApplyReticleStyle()
    if not db then return end
    local r  = db.cursorR     or 0.91
    local g  = db.cursorG     or 0.78
    local b  = db.cursorB     or 0.29
    local a  = db.cursorAlpha or 0.85
    local sz = db.cursorSize  or 32

    -- Color all ring lines
    for _, ln in ipairs(ringLines) do
        ln:SetColorTexture(r, g, b, a)
    end
    -- Color crosshair lines
    lineTop:SetColorTexture(r, g, b, a)
    lineBottom:SetColorTexture(r, g, b, a)
    lineLeft:SetColorTexture(r, g, b, a)
    lineRight:SetColorTexture(r, g, b, a)
    -- Color dot
    dotTex:SetColorTexture(r, g, b, a)
end

-- RebuildReticle is now just a style refresh — no new objects created
local function RebuildReticle()
    ApplyReticleStyle()
end

local function BuildReticle()
    ApplyReticleStyle()
end

------------------------------------------------------------------------
-- Per-frame update: move frame to cursor and recompute line positions
------------------------------------------------------------------------
local function UpdateReticle()
    if not db or not db.cursorEnabled then
        reticleFrame:Hide(); return
    end
    if db.cursorHideInCombat and InCombatLockdown() then
        reticleFrame:Hide(); return
    end
    if db.cursorInstanceOnly then
        local inInst, iType = IsInInstance()
        if not inInst or not AlertsEnabledForType(iType) then
            reticleFrame:Hide(); return
        end
    end
    -- Hide when cursor is over interactive UI (buttons, panels, etc.)
    local focus = GetMouseFocus and GetMouseFocus()
    if focus and focus ~= WorldFrame and focus ~= UIParent then
        reticleFrame:Hide(); return
    end

    local scale = UIParent:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    if not cx or not cy then reticleFrame:Hide(); return end

    -- Position the frame so its CENTER is on the cursor
    local fx = cx / scale
    local fy = cy / scale
    reticleFrame:ClearAllPoints()
    reticleFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", fx, fy)

    -- Geometry values derived from current size setting
    local sz  = db.cursorSize or 32
    local gap = sz * 0.35      -- gap from center to start of crosshair line
    local len = sz * 0.45      -- length of each crosshair arm

    -- Ring: 32 segments around the frame CENTER (0, 0 in SetStartPoint offsets)
    for i = 1, RING_SEGMENTS do
        local a1 = (i - 1) / RING_SEGMENTS * math.pi * 2
        local a2 =  i      / RING_SEGMENTS * math.pi * 2
        ringLines[i]:SetStartPoint("CENTER", reticleFrame,
            sz * math.cos(a1), sz * math.sin(a1))
        ringLines[i]:SetEndPoint("CENTER", reticleFrame,
            sz * math.cos(a2), sz * math.sin(a2))
    end

    -- Crosshair arms (gap keeps center clear)
    lineTop:SetStartPoint("CENTER", reticleFrame, 0,    gap)
    lineTop:SetEndPoint(  "CENTER", reticleFrame, 0,    gap + len)
    lineBottom:SetStartPoint("CENTER", reticleFrame, 0, -gap)
    lineBottom:SetEndPoint(  "CENTER", reticleFrame, 0, -(gap + len))
    lineLeft:SetStartPoint("CENTER", reticleFrame, -gap,    0)
    lineLeft:SetEndPoint(  "CENTER", reticleFrame, -(gap + len), 0)
    lineRight:SetStartPoint("CENTER", reticleFrame, gap,    0)
    lineRight:SetEndPoint(  "CENTER", reticleFrame, gap + len, 0)

    -- Dot stays at CENTER via SetPoint set once at creation
    reticleFrame:Show()
end

local reticleTicker = CreateFrame("Frame")
reticleTicker:SetScript("OnUpdate", function()
    if db then UpdateReticle() end
end)

------------------------------------------------------------------------
-- Event Frame
------------------------------------------------------------------------
local frame = CreateFrame("Frame", "AdventureKitFrame", UIParent)

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("UPDATE_INVENTORY_DURABILITY")
frame:RegisterEvent("UNIT_DIED")
frame:RegisterEvent("CHALLENGE_MODE_START")  -- fires when M+ key is activated
frame:RegisterUnitEvent("UNIT_AURA", "player")

frame:SetScript("OnEvent", function(self, event, arg1, ...)

    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        AdventureKitDB = AdventureKitDB or {}
        db = AdventureKitDB
        ApplyDefaults()

        hudFrame:SetScale(db.hudScale or 1.5)
        hudFrame:ClearAllPoints()
        hudFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", db.hudX, db.hudY)

        Print("v" .. ADDON_VERSION .. " loaded. Type |cffffff00/ak|r for options.")
        -- Build reticle after db is ready
        SafeCall(BuildReticle)
        C_Timer.After(1, function()
            if db then SafeCall(RefreshBuffHUD) end
        end)
        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_LOGOUT" then
        -- db is a live reference to AdventureKitDB; nothing to do

    elseif event == "MERCHANT_SHOW" then
        -- Delay repair so other MERCHANT_SHOW listeners (e.g. TitanRepair)
        -- finish their scans first. Stacking API calls on the same frame tick
        -- causes TitanRepair to exceed its script execution time limit.
        C_Timer.After(0.5, function()
            SafeCall(AutoRepair)
        end)
        -- Sell greys after repair has settled
        C_Timer.After(1.0, function()
            SafeCall(AutoSellGreyItems)
        end)

    elseif event == "PLAYER_ENTERING_WORLD" then
        durabilityWarned = false
        _cachedIsPetClass = nil   -- reset so we re-detect after load
        petGraceActive    = true  -- suppress pet HUD row until pet loads in
        C_Timer.After(8, function()
            petGraceActive = false
            if db then SafeCall(RefreshBuffHUD) end
        end)
        C_Timer.After(2, function()
            if not db then return end
            IsPetClass()   -- warm cache once player unit is ready
            SafeCall(CheckGearDurability)
            SafeCall(RefreshBuffHUD)
        end)
        SafeCall(RunInstanceAlerts)

    elseif event == "ZONE_CHANGED_NEW_AREA" then
        durabilityWarned = false
        petGraceActive    = true
        C_Timer.After(8, function()
            petGraceActive = false
            if db then SafeCall(RefreshBuffHUD) end
        end)
        SafeCall(RefreshBuffHUD)
        SafeCall(RunInstanceAlerts)

    elseif event == "CHALLENGE_MODE_START" then
        -- Fires when the M+ key is activated and the timer begins.
        -- Blizzard auto-dismisses pets when the key is inserted, so we run
        -- a dedicated pet check after a delay to give the player time to
        -- resummon before alerting. Flask/food are checked immediately since
        -- the player should already have those active before the key goes in.
        if not db then return end

        -- Immediate HUD refresh — pet row will show "No Pet!" right away
        -- so the player sees it the moment the key starts.
        SafeCall(RefreshBuffHUD)

        -- Pet chat alert: 10s grace window to resummon after key activation.
        C_Timer.After(10, function()
            if not db then return end
            if not db.alertPet then return end
            if not IsPetClass() then return end
            local inInstance, iType = IsInInstance()
            if not inInstance or iType ~= "party" then return end
            local ps = PetStatus()
            if ps == "none" then
                Print("|cffff4444[M+ Timer Started]|r No pet summoned — resummon before the first pull!")
            elseif ps == "dead" then
                Print("|cffff4444[M+ Timer Started]|r Pet is dead — resurrect before the first pull!")
            end
        end)

    elseif event == "UNIT_AURA" then
        -- Scoped to "player" via RegisterUnitEvent; fires frequently in combat
        SafeCall(RefreshBuffHUD)

    elseif event == "UPDATE_INVENTORY_DURABILITY" then
        if not durabilityWarned then
            SafeCall(CheckGearDurability)
            durabilityWarned = true
            C_Timer.After(60, function() durabilityWarned = false end)
        end

    elseif event == "UNIT_DIED" then
        -- In WoW 12.x Delves and phased combat, the unitID in arg1 may be a
        -- "secret string" — tainted by the engine. Any direct == comparison
        -- against a secret string propagates the taint and throws an error.
        -- We wrap the comparison in pcall: if it errors (tainted), we bail
        -- silently. If it succeeds and arg1 is not "pet", we also bail.
        local isPet = false
        local ok = pcall(function()
            isPet = (arg1 == "pet")
        end)
        if not ok or not isPet then return end

        if not db then return end
        if not db.alertPetDeath then return end
        -- muteInCombat intentionally NOT applied: pet death is high-priority.
        if not IsPetClass() then return end
        local inInstance, iType = IsInInstance()
        if inInstance and (iType == "party" or iType == "raid") then
            Print("|cffff4444Your pet has died!|r Revive or resummon before the next pull.")
        end
    end
end)

------------------------------------------------------------------------
-- Slash Commands
------------------------------------------------------------------------
local function ShowHelp()
    if not db then Print("Not yet initialized."); return end
    print(PREFIX .. " v" .. ADDON_VERSION .. " — Commands:")
    print("  |cffffff00/ak repair|r      Toggle auto-repair (" .. (db.autoRepair and "ON" or "OFF") .. ")")
    print("  |cffffff00/ak guild|r       Toggle guild bank repair (" .. (db.useGuildRepair and "ON" or "OFF") .. ")")
    print("  |cffffff00/ak sell|r        Toggle auto-sell greys (" .. (db.autoSellGrey and "ON" or "OFF") .. ")")
    print("  |cffffff00/ak dungeon|r     Toggle dungeon alerts (" .. (db.alertInDungeon and "ON" or "OFF") .. ")")
    print("  |cffffff00/ak raid|r        Toggle raid alerts (" .. (db.alertInRaid and "ON" or "OFF") .. ")")
    print("  |cffffff00/ak delve|r       Toggle delve alerts (" .. (db.alertInDelve and "ON" or "OFF") .. ")")
    print("  |cffffff00/ak flask|r       Toggle flask alert (" .. (db.alertFlask and "ON" or "OFF") .. ")")
    print("  |cffffff00/ak food|r        Toggle food buff alert (" .. (db.alertFood and "ON" or "OFF") .. ")")
    print("  |cffffff00/ak pet|r         Toggle pet entry alert (" .. (db.alertPet and "ON" or "OFF") .. ")")
    print("  |cffffff00/ak petdeath|r    Toggle pet death alert (" .. (db.alertPetDeath and "ON" or "OFF") .. ")")
    print("  |cffffff00/ak buffs|r       Toggle raid buff alerts (" .. (db.alertRaidBuffs and "ON" or "OFF") .. ")")
    print("  |cffffff00/ak mute|r        Suppress alerts in combat (" .. (db.muteInCombat and "ON" or "OFF") .. ")")
    print("  |cffffff00/ak hud|r         Toggle flask/food HUD (" .. (db.showBuffHUD and "ON" or "OFF") .. ")")
    print("  |cffffff00/ak hudshow|r     HUD always-visible (" .. (db.buffHUDAlwaysShow and "ON" or "OFF") .. ")")
    print("  |cffffff00/ak durability|r  Toggle durability warnings (" .. (db.durabilityCheck and "ON" or "OFF") .. ")")
    print("  |cffffff00/ak threshold #|r Set durability threshold (current: " .. db.durabilityThreshold .. "%)")
    print("  |cffffff00/ak check|r       Run durability check now")
    print("  |cffffff00/ak status|r      Show all settings")
end

local function ShowStatus()
    if not db then Print("Not yet initialized."); return end
    print(PREFIX .. " Current Settings:")
    print("  Auto-Repair:        " .. (db.autoRepair       and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    print("  Guild Repair:       " .. (db.useGuildRepair   and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    print("  Auto-Sell Greys:    " .. (db.autoSellGrey     and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    print("  Alert in Dungeons:  " .. (db.alertInDungeon   and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    print("  Alert in Raids:     " .. (db.alertInRaid      and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    print("  Alert in Delves:    " .. (db.alertInDelve     and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    print("    Flask Alert:      " .. (db.alertFlask       and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    print("    Food Alert:       " .. (db.alertFood        and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    print("    Pet Entry Alert:  " .. (db.alertPet         and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    print("    Pet Death Alert:  " .. (db.alertPetDeath    and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    print("    Raid Buff Alert:  " .. (db.alertRaidBuffs   and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    print("    Mute In Combat:   " .. (db.muteInCombat     and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    print("  Buff HUD:           " .. (db.showBuffHUD      and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    print("  HUD Always Visible: " .. (db.buffHUDAlwaysShow and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    print("  HUD Locked:         " .. (db.hudLocked        and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    print("  Durability Warn:    " .. (db.durabilityCheck  and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    print("  Durability Thresh:  |cffffff00" .. db.durabilityThreshold .. "%|r")
end

local function Toggle(key, label)
    if not db then Print("Not yet initialized."); return end
    db[key] = not db[key]
    Print(label .. " " .. (db[key] and "|cff00ff00enabled|r" or "|cffff4444disabled|r"))
end

SLASH_ADVENTUREKIT1 = "/ak"
SLASH_ADVENTUREKIT2 = "/adventurekit"

SlashCmdList["ADVENTUREKIT"] = function(input)
    local cmd, arg = input:match("^(%S+)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()

    if     cmd == "repair"     then Toggle("autoRepair",       "Auto-repair")
    elseif cmd == "guild"      then Toggle("useGuildRepair",   "Guild bank repair")
    elseif cmd == "sell"       then Toggle("autoSellGrey",     "Auto-sell greys")
    elseif cmd == "dungeon"    then Toggle("alertInDungeon",   "Dungeon alerts")
    elseif cmd == "raid"       then Toggle("alertInRaid",      "Raid alerts")
    elseif cmd == "delve"      then Toggle("alertInDelve",     "Delve alerts")
    elseif cmd == "flask"      then Toggle("alertFlask",       "Flask alert")
    elseif cmd == "food"       then Toggle("alertFood",        "Food buff alert")
    elseif cmd == "pet"        then Toggle("alertPet",         "Pet entry alert")
    elseif cmd == "petdeath"   then Toggle("alertPetDeath",    "Pet death alert")
    elseif cmd == "buffs"      then Toggle("alertRaidBuffs",   "Raid buff alerts")
    elseif cmd == "mute"       then Toggle("muteInCombat",     "Suppress alerts in combat")
    elseif cmd == "hud"        then Toggle("showBuffHUD",      "Buff HUD"); SafeCall(RefreshBuffHUD)
    elseif cmd == "hudshow"    then Toggle("buffHUDAlwaysShow","HUD always-visible"); SafeCall(RefreshBuffHUD)
    elseif cmd == "durability" then Toggle("durabilityCheck",  "Durability warning")
    elseif cmd == "threshold"  then
        if not db then Print("Not yet initialized."); return end
        local n = tonumber(arg)
        if n and n >= 1 and n <= 100 then
            db.durabilityThreshold = n
            Print("Durability threshold set to |cffffff00" .. n .. "%|r")
        else
            Print("Usage: /ak threshold <1-100>")
        end
    elseif cmd == "check"  then SafeCall(CheckGearDurability)
    elseif cmd == "status" then ShowStatus()
    else ShowHelp()
    end
end

------------------------------------------------------------------------
-- ESC > Interface > AddOns panel  (scrollable)
------------------------------------------------------------------------
local optPanel = CreateFrame("Frame", "AdventureKitOptionsPanel")
optPanel.name = "AdventureKit"

optPanel:SetScript("OnShow", function(self)
    if self.built then return end
    self.built = true

    local title = self:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("AdventureKit")
    title:SetTextColor(0, 0.8, 1, 1)

    local sub = self:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    sub:SetText("Auto-repair  |  Auto-sell  |  Alerts  |  Durability  |  HUD  |  Speed  |  Cursor  •  v" .. ADDON_VERSION .. "  •  morphe#11766")
    sub:SetTextColor(0.55, 0.55, 0.55, 1)

    local sf = CreateFrame("ScrollFrame", "AdventureKitScroll", self, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     self, "TOPLEFT",     4,   -52)
    sf:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -28,   4)

    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(sf:GetWidth() or 500, 100)  -- height updated dynamically at end of build
    sf:SetScrollChild(content)

    local function MakeDivider(yPos)
        local d = content:CreateTexture(nil, "BACKGROUND")
        d:SetHeight(1)
        d:SetPoint("TOPLEFT",  content, "TOPLEFT",   6, yPos)
        d:SetPoint("TOPRIGHT", content, "TOPRIGHT", -6, yPos)
        d:SetColorTexture(0.3, 0.3, 0.3, 0.8)
    end

    local function MakeHeader(text, yPos)
        local lbl = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        lbl:SetPoint("TOPLEFT", content, "TOPLEFT", 10, yPos)
        lbl:SetText(text)
        lbl:SetTextColor(1, 0.82, 0, 1)
    end

    local function MakeCheckbox(label, key, yPos)
        local cb = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", content, "TOPLEFT", 10, yPos)
        cb:SetChecked(db and db[key] or false)
        cb.text:SetText(label)
        cb:SetScript("OnClick", function(btn)
            if db then db[key] = btn:GetChecked() end
        end)
        return cb
    end

    -- VENDOR AUTOMATION
    MakeHeader("Vendor Automation", -10)
    MakeCheckbox("Auto-repair at repair vendor",       "autoRepair",     -30)
    MakeCheckbox("Prefer guild bank for repair gold",  "useGuildRepair", -54)
    MakeCheckbox("Auto-sell grey (poor) items",        "autoSellGrey",   -78)

    -- DURABILITY
    MakeDivider(-108)
    MakeHeader("Durability", -118)
    MakeCheckbox("Warn when gear below durability threshold", "durabilityCheck", -138)

    local threshLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    threshLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 30, -166)
    threshLabel:SetText("Threshold %:")

    local threshBox = CreateFrame("EditBox", "AKThresholdBox", content, "InputBoxTemplate")
    threshBox:SetPoint("LEFT", threshLabel, "RIGHT", 8, 0)
    threshBox:SetSize(50, 20)
    threshBox:SetAutoFocus(false)
    threshBox:SetNumeric(true)
    threshBox:SetMaxLetters(3)
    threshBox:SetText(tostring(db and db.durabilityThreshold or 50))
    threshBox:SetScript("OnEnterPressed", function(eb)
        local n = tonumber(eb:GetText())
        if db and n and n >= 1 and n <= 100 then
            db.durabilityThreshold = n
        else
            eb:SetText(tostring(db and db.durabilityThreshold or 50))
        end
        eb:ClearFocus()
    end)

    -- ENTRY ALERTS
    MakeDivider(-192)
    MakeHeader("Entry alerts", -202)

    local alertNote = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    alertNote:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -220)
    alertNote:SetPoint("TOPRIGHT", content, "TOPRIGHT", -10, -220)
    alertNote:SetText("Choose which content triggers alerts. Uncheck all to disable.")
    alertNote:SetTextColor(0.55, 0.55, 0.55, 1)

    -- ── Relative-anchor helpers ──────────────────────────────────────
    -- cursor tracks the current Y offset from content top.
    -- Every element advances cursor by its own height + padding.
    local cursor = -238  -- start just below the alert note

    local function Advance(px) cursor = cursor - px end

    local function RelSubHeader(text)
        local lbl = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        lbl:SetPoint("TOPLEFT", content, "TOPLEFT", 10, cursor)
        lbl:SetText(text)
        lbl:SetTextColor(0.8, 0.75, 0.5, 1)
        Advance(18)  -- subheader height + gap
        return lbl
    end

    local function RelNote(text, indent)
        local lbl = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        lbl:SetPoint("TOPLEFT", content, "TOPLEFT", indent or 10, cursor)
        lbl:SetText(text)
        lbl:SetTextColor(0.45, 0.45, 0.45, 1)
        Advance(16)
        return lbl
    end

    local function RelCB(label, key, indent, sublabel)
        local cb = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", content, "TOPLEFT", indent or 10, cursor)
        cb:SetChecked(db and db[key] or false)
        cb.text:SetText(label)
        cb:SetScript("OnClick", function(btn)
            if db then db[key] = btn:GetChecked() end
        end)
        Advance(24)  -- checkbox height
        if sublabel then
            local sl = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            sl:SetPoint("TOPLEFT", content, "TOPLEFT", (indent or 10) + 24, cursor)
            sl:SetText(sublabel)
            sl:SetTextColor(0.5, 0.5, 0.5, 1)
            Advance(16)  -- sublabel height
        end
        Advance(4)   -- gap between rows
        return cb
    end

    local function RelDivider()
        Advance(6)
        local d = content:CreateTexture(nil, "BACKGROUND")
        d:SetHeight(1)
        d:SetPoint("TOPLEFT",  content, "TOPLEFT",   6, cursor)
        d:SetPoint("TOPRIGHT", content, "TOPRIGHT", -6, cursor)
        d:SetColorTexture(0.3, 0.3, 0.3, 0.8)
        Advance(10)
    end

    local function RelSectionHeader(text)
        local lbl = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        lbl:SetPoint("TOPLEFT", content, "TOPLEFT", 10, cursor)
        lbl:SetText(text)
        lbl:SetTextColor(1, 0.82, 0, 1)
        Advance(22)
        return lbl
    end

    -- ── ALERT WHEN ENTERING ──────────────────────────────────────────
    RelSubHeader("Alert when entering")
    RelCB("Dungeons (including Mythic+)", "alertInDungeon", 24)
    RelCB("Raids",                        "alertInRaid",    24)
    RelCB("Delves",                       "alertInDelve",   24)
    Advance(4)

    -- ── FLASK & FOOD ─────────────────────────────────────────────────
    RelSubHeader("Flask & food")
    RelCB("Missing flask",                   "alertFlask",     24)
    RelCB("Missing food buff",               "alertFood",      24)
    RelCB("Missing your buff to party/raid", "alertRaidBuffs", 24)
    Advance(4)

    -- ── PET ──────────────────────────────────────────────────────────
    RelSubHeader("Pet")
    RelNote("BM/Surv Hunter  ·  Warlock  ·  Unholy DK  ·  Frost Mage", 38)
    RelCB("No pet summoned on entry", "alertPet", 24,
        "MM Hunters and non-Unholy DKs excluded automatically")
    RelCB("Pet died mid-run", "alertPetDeath", 24,
        "Fires even when suppress-in-combat is on")
    Advance(4)

    RelCB("Suppress alerts while in combat", "muteInCombat", 10,
        "Does not suppress pet death alerts")

    -- ── ON-SCREEN BUFF ALERTS ────────────────────────────────────────
    RelDivider()
    RelSectionHeader("On-Screen Buff Alerts")
    RelCB("Show flashing alerts on screen", "showBuffHUD", 10)

    local alwaysCB = RelCB("Always show HUD (not just in instances)", "buffHUDAlwaysShow", 10)
    alwaysCB:SetScript("OnClick", function(btn)
        if db then
            db.buffHUDAlwaysShow = btn:GetChecked()
            SafeCall(RefreshBuffHUD)
        end
    end)

    RelCB("Lock HUD position (disable dragging)", "hudLocked", 10)

    -- Alert Scale slider
    local hudScaleLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    hudScaleLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 30, cursor)
    hudScaleLabel:SetText("Alert Scale:")
    Advance(16)

    local hudScaleSlider = CreateFrame("Slider", "AKHudScaleSlider", content, "OptionsSliderTemplate")
    hudScaleSlider:SetPoint("TOPLEFT", content, "TOPLEFT", 30, cursor)
    hudScaleSlider:SetWidth(200)
    hudScaleSlider:SetMinMaxValues(0.5, 3.0)
    hudScaleSlider:SetValueStep(0.1)
    hudScaleSlider:SetObeyStepOnDrag(true)
    local initHudScale = (db and db.hudScale) or 1.5
    hudScaleSlider:SetValue(initHudScale)
    AKHudScaleSliderLow:SetText("0.5x")
    AKHudScaleSliderHigh:SetText("3.0x")
    AKHudScaleSliderText:SetText(string.format("%.1f", initHudScale))
    hudScaleSlider:SetScript("OnValueChanged", function(s, val)
        AKHudScaleSliderText:SetText(string.format("%.1f", val))
        HUD_SetScale(val)
    end)
    Advance(40)

    local hudResetBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    hudResetBtn:SetPoint("TOPLEFT", content, "TOPLEFT", 30, cursor)
    hudResetBtn:SetSize(130, 22)
    hudResetBtn:SetText("Reset HUD Position")
    hudResetBtn:SetScript("OnClick", function()
        if db then
            db.hudX, db.hudY = DEFAULTS.hudX, DEFAULTS.hudY
            hudFrame:ClearAllPoints()
            hudFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", db.hudX, db.hudY)
        end
    end)
    Advance(32)

    -- ── SPEED DISPLAY ────────────────────────────────────────────────
    RelDivider()
    RelSectionHeader("Speed Display")

    local speedHideCB = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    speedHideCB:SetPoint("TOPLEFT", content, "TOPLEFT", 10, cursor)
    speedHideCB:SetChecked(AdventureKitDB and AdventureKitDB.SpeedTracker and AdventureKitDB.SpeedTracker.hidden or false)
    speedHideCB.text:SetText("Hide speed display")
    speedHideCB:SetScript("OnClick", function(btn)
        if SpeedTrackerAPI then SpeedTrackerAPI.SetHidden(btn:GetChecked()) end
    end)
    Advance(28)

    local speedLockCB = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    speedLockCB:SetPoint("TOPLEFT", content, "TOPLEFT", 10, cursor)
    speedLockCB:SetChecked(AdventureKitDB and AdventureKitDB.SpeedTracker and AdventureKitDB.SpeedTracker.locked or false)
    speedLockCB.text:SetText("Lock speed frame position (disable dragging)")
    speedLockCB:SetScript("OnClick", function(btn)
        if SpeedTrackerAPI then SpeedTrackerAPI.SetLocked(btn:GetChecked()) end
    end)
    Advance(28)

    local speedLabelCB = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    speedLabelCB:SetPoint("TOPLEFT", content, "TOPLEFT", 10, cursor)
    speedLabelCB:SetChecked(AdventureKitDB and AdventureKitDB.SpeedTracker and
        (AdventureKitDB.SpeedTracker.showLabel ~= false) or true)
    speedLabelCB.text:SetText("Show \"Speed\" label beneath percentage")
    speedLabelCB:SetScript("OnClick", function(btn)
        if SpeedTrackerAPI then SpeedTrackerAPI.SetShowLabel(btn:GetChecked()) end
    end)
    Advance(28)

    local scaleLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    scaleLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 10, cursor)
    scaleLabel:SetText("Frame Scale:")
    Advance(16)

    local scaleSlider = CreateFrame("Slider", "AKSpeedScaleSlider", content, "OptionsSliderTemplate")
    scaleSlider:SetPoint("TOPLEFT", content, "TOPLEFT", 10, cursor)
    scaleSlider:SetWidth(220)
    scaleSlider:SetMinMaxValues(0.5, 2.0)
    scaleSlider:SetValueStep(0.05)
    scaleSlider:SetObeyStepOnDrag(true)
    local initScale = (AdventureKitDB and AdventureKitDB.SpeedTracker and AdventureKitDB.SpeedTracker.scale) or 1.0
    scaleSlider:SetValue(initScale)
    AKSpeedScaleSliderLow:SetText("0.5x")
    AKSpeedScaleSliderHigh:SetText("2.0x")
    AKSpeedScaleSliderText:SetText(string.format("%.2f", initScale))
    scaleSlider:SetScript("OnValueChanged", function(s, val)
        AKSpeedScaleSliderText:SetText(string.format("%.2f", val))
        if SpeedTrackerAPI then SpeedTrackerAPI.SetScale(val) end
    end)
    Advance(40)

    local speedResetBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    speedResetBtn:SetPoint("TOPLEFT", content, "TOPLEFT", 10, cursor)
    speedResetBtn:SetSize(140, 22)
    speedResetBtn:SetText("Reset Speed Position")
    speedResetBtn:SetScript("OnClick", function()
        if SpeedTrackerAPI then SpeedTrackerAPI.ResetPosition() end
    end)
    Advance(32)

    local speedVer = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    speedVer:SetPoint("TOPLEFT", content, "TOPLEFT", 10, cursor)
    speedVer:SetText("Speed v" .. (SpeedTrackerAPI and SpeedTrackerAPI.GetVersion() or "?") .. "  |  /speed for quick commands")
    speedVer:SetTextColor(0.5, 0.5, 0.5, 1)
    Advance(24)

    -- ── CURSOR RETICLE ───────────────────────────────────────────────
    RelDivider()
    RelSectionHeader("Cursor reticle")

    local cursorEnableCB = RelCB("Show reticle on cursor", "cursorEnabled", 10)
    cursorEnableCB:SetScript("OnClick", function(btn)
        if db then
            db.cursorEnabled = btn:GetChecked()
            if not db.cursorEnabled then reticleFrame:Hide() end
        end
    end)

    RelCB("Hide reticle during combat",           "cursorHideInCombat",  10)
    RelCB("Only show in dungeons / raids / delves","cursorInstanceOnly",  10)

    -- Size slider
    local cursorSizeLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    cursorSizeLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 10, cursor)
    cursorSizeLabel:SetText("Reticle size:")
    Advance(16)

    local cursorSizeSlider = CreateFrame("Slider", "AKCursorSizeSlider", content, "OptionsSliderTemplate")
    cursorSizeSlider:SetPoint("TOPLEFT", content, "TOPLEFT", 10, cursor)
    cursorSizeSlider:SetWidth(220)
    cursorSizeSlider:SetMinMaxValues(12, 80)
    cursorSizeSlider:SetValueStep(2)
    cursorSizeSlider:SetObeyStepOnDrag(true)
    cursorSizeSlider:SetValue(db and db.cursorSize or 32)
    AKCursorSizeSliderLow:SetText("12")
    AKCursorSizeSliderHigh:SetText("80")
    AKCursorSizeSliderText:SetText(tostring(db and db.cursorSize or 32))
    cursorSizeSlider:SetScript("OnValueChanged", function(s, val)
        val = math.floor(val)
        AKCursorSizeSliderText:SetText(tostring(val))
        if db then
            db.cursorSize = val
            db.cursorR = db.cursorR  -- preserve color
            SafeCall(RebuildReticle)
        end
    end)
    Advance(40)

    -- Opacity slider
    local cursorAlphaLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    cursorAlphaLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 10, cursor)
    cursorAlphaLabel:SetText("Opacity:")
    Advance(16)

    local cursorAlphaSlider = CreateFrame("Slider", "AKCursorAlphaSlider", content, "OptionsSliderTemplate")
    cursorAlphaSlider:SetPoint("TOPLEFT", content, "TOPLEFT", 10, cursor)
    cursorAlphaSlider:SetWidth(220)
    cursorAlphaSlider:SetMinMaxValues(0.1, 1.0)
    cursorAlphaSlider:SetValueStep(0.05)
    cursorAlphaSlider:SetObeyStepOnDrag(true)
    cursorAlphaSlider:SetValue(db and db.cursorAlpha or 0.85)
    AKCursorAlphaSliderLow:SetText("10%")
    AKCursorAlphaSliderHigh:SetText("100%")
    AKCursorAlphaSliderText:SetText(string.format("%.0f%%", (db and db.cursorAlpha or 0.85) * 100))
    cursorAlphaSlider:SetScript("OnValueChanged", function(s, val)
        AKCursorAlphaSliderText:SetText(string.format("%.0f%%", val * 100))
        if db then
            db.cursorAlpha = val
            SafeCall(RebuildReticle)
        end
    end)
    Advance(40)

    -- Color presets
    local colorLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    colorLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 10, cursor)
    colorLabel:SetText("Color:")
    Advance(20)

    local colors = {
        { name="Gold",  r=0.91, g=0.78, b=0.29 },
        { name="White", r=1.0,  g=1.0,  b=1.0  },
        { name="Red",   r=1.0,  g=0.2,  b=0.2  },
        { name="Cyan",  r=0.2,  g=0.9,  b=1.0  },
        { name="Green", r=0.2,  g=1.0,  b=0.4  },
    }
    local colorBtns = {}
    local btnX = 10
    for _, col in ipairs(colors) do
        local btn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
        btn:SetSize(52, 22)
        btn:SetPoint("TOPLEFT", content, "TOPLEFT", btnX, cursor)
        btn:SetText(col.name)
        local r, g, b = col.r, col.g, col.b
        btn:SetScript("OnClick", function()
            if db then
                db.cursorR, db.cursorG, db.cursorB = r, g, b
                SafeCall(RebuildReticle)
            end
        end)
        table.insert(colorBtns, btn)
        btnX = btnX + 56
    end
    Advance(32)

    -- Update content frame height to match actual content
    content:SetHeight(math.abs(cursor) + 20)
end)

if Settings and Settings.RegisterCanvasLayoutCategory then
    local category = Settings.RegisterCanvasLayoutCategory(optPanel, "AdventureKit")
    Settings.RegisterAddOnCategory(category)
else
    InterfaceOptions_AddCategory(optPanel)
end
