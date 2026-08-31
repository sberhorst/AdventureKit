"""
AdventureKit additions to the shared WoW stub.

Kept out of wow_stub.py on purpose: that file is shared with
ElitistsToolkit, SpeedTracker and Socialite, and stays addon-agnostic.
Anything here is specific to what AdventureKit reads.

TEST additions:
    TEST.specIndex   which specialization tab the player is in
    TEST.specs       index -> { id = <specID>, name = <display name> }
    TEST.specAPI     "modern" (C_SpecializationInfo) | "legacy" | "none"
    TEST.petExists   UnitExists("pet")
    TEST.petHealth   UnitHealth("pet")
    TEST.petDead     UnitIsDead("pet")
    TEST.petBar      PetHasActionBar() -- false for a temporary summon
    TEST.inCombat    InCombatLockdown()

The pet-bar flag is the one that matters. A Death Knight's Raise Dead and
Army of the Dead put a unit in the "pet" slot for under a minute and give
the player no pet action bar, so a stub that only models UnitExists cannot
tell a maintained pet apart from a temporary summon -- which is the whole
distinction the alert now turns on.
"""

EXTRA_LUA = r"""
TEST.specIndex = 1
TEST.specAPI   = "modern"    -- "modern" | "legacy" | "none"
TEST.petExists = false
TEST.petHealth = 0
TEST.petDead   = false
TEST.petBar    = true        -- a real, controllable pet by default
TEST.inCombat  = false

-- Real specialization IDs, as the game reports them. The addon keys its pet
-- table on these rather than on the 1-4 tab index, which only means anything
-- alongside a class.
TEST.specs = {
  BLOOD        = { id = 250, name = "Blood" },
  FROST_DK     = { id = 251, name = "Frost" },
  UNHOLY       = { id = 252, name = "Unholy" },
  BEASTMASTERY = { id = 253, name = "Beast Mastery" },
  MARKSMAN     = { id = 254, name = "Marksmanship" },
  SURVIVAL     = { id = 255, name = "Survival" },
  AFFLICTION   = { id = 265, name = "Affliction" },
  DEMONOLOGY   = { id = 266, name = "Demonology" },
  DESTRUCTION  = { id = 267, name = "Destruction" },
  ARCANE       = { id = 62,  name = "Arcane" },
  FIRE         = { id = 63,  name = "Fire" },
  FROST_MAGE   = { id = 64,  name = "Frost" },
}

-- TEST.specIndex holds the spec ID directly; the "index" the game hands back
-- is opaque to the addon, which only ever passes it straight into the info
-- lookup, so the stub uses one value for both.
local function specIndexFn()
  return TEST.specIndex
end

-- specID, name, description, icon, role, primaryStat
local function specInfoFn(index)
  if not index then return nil end
  for _, s in pairs(TEST.specs) do
    if s.id == index then
      return s.id, s.name, "", 0, "DAMAGER", 1
    end
  end
  return nil
end

-- Exactly one shape at a time. Offering both would let code hardcoded to
-- either one pass, and "none" models the real state during a loading screen,
-- where the addon must stay silent rather than guess.
function TEST.applySpecAPI()
  if TEST.specAPI == "legacy" then
    C_SpecializationInfo = nil
    _G.GetSpecialization = specIndexFn
    _G.GetSpecializationInfo = specInfoFn
  elseif TEST.specAPI == "none" then
    C_SpecializationInfo = nil
    _G.GetSpecialization = nil
    _G.GetSpecializationInfo = nil
  else
    C_SpecializationInfo = {
      GetSpecialization = specIndexFn,
      GetSpecializationInfo = specInfoFn,
    }
    _G.GetSpecialization = nil
    _G.GetSpecializationInfo = nil
  end
end
TEST.applySpecAPI()

UnitExists = function(unit)
  if unit == "pet" then return TEST.petExists end
  return unit == "player"
end
UnitHealth       = function(unit)
                     if unit == "pet" then return TEST.petHealth end
                     return 100
                   end
UnitIsDead       = function(unit)
                     if unit == "pet" then return TEST.petDead end
                     return false
                   end
PetHasActionBar  = function() return TEST.petBar end
InCombatLockdown = function() return TEST.inCombat end
"""
