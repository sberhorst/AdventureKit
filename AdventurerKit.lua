--[[
    AdventurerKit v2.0.0
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
local ADDON_NAME    = "AdventurerKit"
local ADDON_VERSION = "2.2.0"
local PREFIX        = "|cff00ccff[AdventurerKit]|r"

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
local hudFrame = CreateFrame("Frame", "AdventurerKitHUD", UIParent)
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
-- Event Frame
------------------------------------------------------------------------
local frame = CreateFrame("Frame", "AdventurerKitFrame", UIParent)

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
        AdventurerKitDB = AdventurerKitDB or {}
        db = AdventurerKitDB
        ApplyDefaults()

        hudFrame:SetScale(db.hudScale or 1.5)
        hudFrame:ClearAllPoints()
        hudFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", db.hudX, db.hudY)

        Print("v" .. ADDON_VERSION .. " loaded. Type |cffffff00/ak|r for options.")
        C_Timer.After(1, function()
            if db then SafeCall(RefreshBuffHUD) end
        end)
        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_LOGOUT" then
        -- db is a live reference to AdventurerKitDB; nothing to do

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

SLASH_ADVENTURERKIT1 = "/ak"
SLASH_ADVENTURERKIT2 = "/adventurerkit"

SlashCmdList["ADVENTURERKIT"] = function(input)
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
local optPanel = CreateFrame("Frame", "AdventurerKitOptionsPanel")
optPanel.name = "AdventurerKit"

optPanel:SetScript("OnShow", function(self)
    if self.built then return end
    self.built = true

    local title = self:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("AdventurerKit")
    title:SetTextColor(0, 0.8, 1, 1)

    local sub = self:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    sub:SetText("Auto-repair  |  Auto-sell  |  Alerts  |  Durability  |  Buff Alerts  |  Speed  •  v" .. ADDON_VERSION .. "  •  morphe#11766")
    sub:SetTextColor(0.55, 0.55, 0.55, 1)

    local sf = CreateFrame("ScrollFrame", "AdventurerKitScroll", self, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     self, "TOPLEFT",     4,   -52)
    sf:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -28,   4)

    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(sf:GetWidth() or 500, 1080)
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

    -- Sub-header helper (dimmed, non-checkbox label)
    local function MakeSubHeader(text, yPos)
        local lbl = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        lbl:SetPoint("TOPLEFT", content, "TOPLEFT", 10, yPos)
        lbl:SetText(text)
        lbl:SetTextColor(0.8, 0.75, 0.5, 1)
    end

    -- Indented checkbox (24px left)
    local function MakeIndentCB(label, key, yPos, sublabel)
        local cb = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", content, "TOPLEFT", 24, yPos)
        cb:SetChecked(db and db[key] or false)
        cb.text:SetText(label)
        cb:SetScript("OnClick", function(btn)
            if db then db[key] = btn:GetChecked() end
        end)
        if sublabel then
            local sl = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            sl:SetPoint("TOPLEFT", content, "TOPLEFT", 48, yPos - 16)
            sl:SetText(sublabel)
            sl:SetTextColor(0.5, 0.5, 0.5, 1)
        end
        return cb
    end

    MakeSubHeader("Alert when entering", -238)
    MakeIndentCB("Dungeons (including Mythic+)", "alertInDungeon", -254)
    MakeIndentCB("Raids",                        "alertInRaid",    -278)
    MakeIndentCB("Delves",                       "alertInDelve",   -302)

    MakeSubHeader("Flask & food", -330)
    MakeIndentCB("Missing flask",                "alertFlask",     -346)
    MakeIndentCB("Missing food buff",            "alertFood",      -370)
    MakeIndentCB("Missing your buff to party/raid", "alertRaidBuffs", -394)

    MakeSubHeader("Pet", -422)
    local noEntryNote = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    noEntryNote:SetPoint("TOPLEFT", content, "TOPLEFT", 38, -424)
    noEntryNote:SetText("BM/Surv Hunter · Warlock · Unholy DK · Frost Mage")
    noEntryNote:SetTextColor(0.45, 0.45, 0.45, 1)

    MakeIndentCB("No pet summoned on entry", "alertPet", -438,
        "MM Hunters and non-Unholy DKs are excluded automatically by spec")
    MakeIndentCB("Pet died mid-run",         "alertPetDeath", -470,
        "Fires even when suppress-in-combat is on")

    MakeCheckbox("Suppress alerts while in combat", "muteInCombat", -506)
    local muteNote = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    muteNote:SetPoint("TOPLEFT", content, "TOPLEFT", 34, -524)
    muteNote:SetText("Does not suppress pet death alerts")
    muteNote:SetTextColor(0.45, 0.45, 0.45, 1)

    -- ON-SCREEN BUFF ALERTS
    MakeDivider(-542)
    MakeHeader("On-Screen Buff Alerts", -552)
    MakeCheckbox("Show flashing alerts on screen", "showBuffHUD", -572)

    local alwaysCB = MakeCheckbox("Always show HUD (not just in instances)", "buffHUDAlwaysShow", -596)
    alwaysCB:SetScript("OnClick", function(btn)
        if db then
            db.buffHUDAlwaysShow = btn:GetChecked()
            SafeCall(RefreshBuffHUD)
        end
    end)

    MakeCheckbox("Lock HUD position (disable dragging)", "hudLocked", -620)

    -- Scale slider
    local hudScaleLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    hudScaleLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 30, -648)
    hudScaleLabel:SetText("Alert Scale:")

    local hudScaleSlider = CreateFrame("Slider", "AKHudScaleSlider", content, "OptionsSliderTemplate")
    hudScaleSlider:SetPoint("TOPLEFT", content, "TOPLEFT", 30, -668)
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

    local hudResetBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    hudResetBtn:SetPoint("TOPLEFT", content, "TOPLEFT", 30, -716)
    hudResetBtn:SetSize(130, 22)
    hudResetBtn:SetText("Reset HUD Position")
    hudResetBtn:SetScript("OnClick", function()
        if db then
            db.hudX, db.hudY = DEFAULTS.hudX, DEFAULTS.hudY
            hudFrame:ClearAllPoints()
            hudFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", db.hudX, db.hudY)
        end
    end)

    -- SPEED DISPLAY
    MakeDivider(-742)
    MakeHeader("Speed Display", -752)

    local speedHideCB = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    speedHideCB:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -772)
    speedHideCB:SetChecked(AdventurerKitDB and AdventurerKitDB.SpeedTracker and AdventurerKitDB.SpeedTracker.hidden or false)
    speedHideCB.text:SetText("Hide speed display")
    speedHideCB:SetScript("OnClick", function(btn)
        if SpeedTrackerAPI then SpeedTrackerAPI.SetHidden(btn:GetChecked()) end
    end)

    local speedLockCB = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    speedLockCB:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -796)
    speedLockCB:SetChecked(AdventurerKitDB and AdventurerKitDB.SpeedTracker and AdventurerKitDB.SpeedTracker.locked or false)
    speedLockCB.text:SetText("Lock speed frame position (disable dragging)")
    speedLockCB:SetScript("OnClick", function(btn)
        if SpeedTrackerAPI then SpeedTrackerAPI.SetLocked(btn:GetChecked()) end
    end)

    local speedLabelCB = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    speedLabelCB:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -820)
    speedLabelCB:SetChecked(AdventurerKitDB and AdventurerKitDB.SpeedTracker and
        (AdventurerKitDB.SpeedTracker.showLabel ~= false) or true)
    speedLabelCB.text:SetText("Show \"Speed\" label beneath percentage")
    speedLabelCB:SetScript("OnClick", function(btn)
        if SpeedTrackerAPI then SpeedTrackerAPI.SetShowLabel(btn:GetChecked()) end
    end)

    local scaleLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    scaleLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -850)
    scaleLabel:SetText("Frame Scale:")

    local scaleSlider = CreateFrame("Slider", "AKSpeedScaleSlider", content, "OptionsSliderTemplate")
    scaleSlider:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -870)
    scaleSlider:SetWidth(220)
    scaleSlider:SetMinMaxValues(0.5, 2.0)
    scaleSlider:SetValueStep(0.05)
    scaleSlider:SetObeyStepOnDrag(true)
    local initScale = (AdventurerKitDB and AdventurerKitDB.SpeedTracker and AdventurerKitDB.SpeedTracker.scale) or 1.0
    scaleSlider:SetValue(initScale)
    AKSpeedScaleSliderLow:SetText("0.5x")
    AKSpeedScaleSliderHigh:SetText("2.0x")
    AKSpeedScaleSliderText:SetText(string.format("%.2f", initScale))
    scaleSlider:SetScript("OnValueChanged", function(s, val)
        AKSpeedScaleSliderText:SetText(string.format("%.2f", val))
        if SpeedTrackerAPI then SpeedTrackerAPI.SetScale(val) end
    end)

    local speedResetBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    speedResetBtn:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -918)
    speedResetBtn:SetSize(140, 22)
    speedResetBtn:SetText("Reset Speed Position")
    speedResetBtn:SetScript("OnClick", function()
        if SpeedTrackerAPI then SpeedTrackerAPI.ResetPosition() end
    end)

    local speedVer = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    speedVer:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -948)
    speedVer:SetText("Speed v" .. (SpeedTrackerAPI and SpeedTrackerAPI.GetVersion() or "?") .. "  |  /speed for quick commands")
    speedVer:SetTextColor(0.5, 0.5, 0.5, 1)
end)

if Settings and Settings.RegisterCanvasLayoutCategory then
    local category = Settings.RegisterCanvasLayoutCategory(optPanel, "AdventurerKit")
    Settings.RegisterAddOnCategory(category)
else
    InterfaceOptions_AddCategory(optPanel)
end
