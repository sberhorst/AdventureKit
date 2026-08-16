"""
Minimal World of Warcraft API stub for testing addon Lua outside the game.

There is no Lua toolchain on a typical Windows dev box, and no way to run
WoW headlessly. `lupa` embeds a real Lua runtime in Python, so we can load
the addon's actual .lua files against a fake Blizzard API and assert on the
behaviour of individual functions.

The point is not to simulate WoW. It is to model the *contract* the addon
depends on -- especially the parts Blizzard changes between patches -- so
that a patch-day breakage can be reproduced and then proven fixed.

Usage:
    from wow_stub import load_addon, Check

    lua = load_addon(["AdventureKit.lua"], exports=["HasFlask", "HasFood"])
    g = lua.globals()
    g.TEST.restricted = True
    ...

Requires: pip install lupa
"""

import os
import sys

try:
    from lupa import LuaRuntime
except ImportError:  # pragma: no cover
    sys.exit(
        "lupa is not installed. Run:\n\n    pip install lupa\n\n"
        "It embeds a real Lua interpreter so these tests can execute the "
        "addon's actual source."
    )

ADDON_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# ---------------------------------------------------------------------------
# The stub itself.
#
# TEST is the control surface: tests mutate it to describe the game state
# they want, then call into the addon.
#
#   TEST.auras       - list of { name = ..., spellID = ... } on the unit
#   TEST.restricted  - True to simulate 12.1 Secret Auras (see below)
#   TEST.spellNames  - spellID -> localised name, for C_Spell.GetSpellName
#   TEST.prints      - everything the addon printed to chat
# ---------------------------------------------------------------------------
PRELUDE = r"""
_G.TEST = { auras = {}, restricted = false, prints = {}, spellNames = {} }

-- A frame whose every method returns the frame, so chained UI setup in the
-- addon runs without us having to enumerate the widget API.
local function stubframe()
  local f = {}
  return setmetatable(f, {__index = function() return function() return f end end})
end

CreateFrame  = function() return stubframe() end
UIParent     = stubframe()
GetTime      = function() return 0 end
print        = function(...)
                 local s = ""
                 for i = 1, select('#', ...) do s = s .. tostring((select(i, ...))) end
                 table.insert(TEST.prints, s)
               end

C_Timer              = { After = function() end }
InCombatLockdown     = function() return false end
IsInInstance         = function() return false, "none" end
IsInRaid             = function() return false end
GetNumGroupMembers   = function() return 0 end
UnitExists           = function(u) return u == "player" end
UnitClass            = function() return "Mage", "MAGE" end
UnitHealth           = function() return 100 end
UnitIsDead           = function() return false end
UnitAffectingCombat  = function() return false end
GetCoinTextureString = function(v) return tostring(v) end
GetCursorPosition    = function() return 0, 0 end
GetUnitSpeed         = function() return 0 end
GetMouseFocus        = nil
GetMouseFoci         = function() return {} end
hooksecurefunc       = function() end
SlashCmdList         = {}

-- Merchant / durability / bags
GetInventoryItemDurability = function() return nil end
GetInventoryItemLink       = function() return nil end
GetMoney                   = function() return 0 end
GetGuildBankMoney          = function() return 0 end
GetRepairAllCost           = function() return 0, false end
CanMerchantRepair          = function() return false end
GetItemInfo                = function() return nil end
C_Container = {
  GetContainerNumSlots      = function() return 0 end,
  GetContainerItemInfo      = function() return nil end,
  GetContainerItemQuestInfo = function() return nil end,
  UseContainerItem          = function() end,
}

INVSLOT_HEAD, INVSLOT_NECK, INVSLOT_SHOULDER, INVSLOT_CHEST     = 1, 2, 3, 5
INVSLOT_WAIST, INVSLOT_LEGS, INVSLOT_FEET, INVSLOT_WRIST        = 6, 7, 8, 9
INVSLOT_HAND, INVSLOT_FINGER1, INVSLOT_FINGER2                  = 10, 11, 12
INVSLOT_TRINKET1, INVSLOT_TRINKET2                              = 13, 14
INVSLOT_BACK, INVSLOT_MAINHAND, INVSLOT_OFFHAND, INVSLOT_RANGED = 15, 16, 17, 18

-- Options UI
Settings = nil
InterfaceOptions_AddCategory = function() end

C_ChallengeMode = { IsChallengeModeActive = function() return false end }
C_Spell = { GetSpellName = function(id) return TEST.spellNames[id] end }

-- -------------------------------------------------------------------------
-- Patch 12.1.0 (Midnight) -- Secret Auras.
--
-- While auras are secret (combat, boss encounters, Mythic+, PvP), every
-- C_UnitAuras entry point that reaches aura data BY INDEX, SLOT, OR
-- INSTANCE ID raises a Lua error when called from an addon. The spell-ID
-- and spell-name entry points keep working for non-secret spells.
--
-- TEST.restricted = true models that. This is the single most important
-- thing in this file: it is what lets a test prove the addon still tells
-- the truth mid-pull instead of silently reporting every buff as missing.
-- -------------------------------------------------------------------------
C_UnitAuras = {
  GetBuffDataByIndex = function(unit, i)
    if TEST.restricted then error("attempted to access secret aura data") end
    local a = TEST.auras[i]
    if not a then return nil end
    return { name = a.name, spellId = a.spellID }
  end,

  GetAuraDataByIndex = function(unit, i, filter)
    if TEST.restricted then error("attempted to access secret aura data") end
    local a = TEST.auras[i]
    if not a then return nil end
    return { name = a.name, spellId = a.spellID }
  end,

  GetPlayerAuraBySpellID = function(id)
    for _, a in ipairs(TEST.auras) do
      if a.spellID == id then return { name = a.name, spellId = a.spellID } end
    end
    return nil
  end,

  GetAuraDataBySpellName = function(unit, name, filter)
    for _, a in ipairs(TEST.auras) do
      if a.name == name then return { name = a.name, spellId = a.spellID } end
    end
    return nil
  end,
}
"""


def load_addon(files, exports=(), extra_lua=""):
    """Load addon .lua files under the stub.

    files   -- filenames relative to the addon root, in TOC order.
    exports -- names of addon *locals* to re-expose on _G as T_<name>,
               since Lua locals are otherwise unreachable from the harness.
    """
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)
    if extra_lua:
        lua.execute(extra_lua)

    source = []
    for name in files:
        path = os.path.join(ADDON_ROOT, name)
        with open(path, encoding="utf-8") as fh:
            source.append(fh.read())

    tail = "\n".join(f"_G.T_{n} = {n}" for n in exports)
    lua.execute("\n".join(source) + "\n" + tail + "\n")
    return lua


def set_auras(lua, pairs_):
    """Set TEST.auras from a list of (name, spellID) tuples."""
    lua.globals().TEST.auras = lua.table_from(
        [lua.table_from({"name": n, "spellID": i}) for n, i in pairs_]
    )


class Check:
    """Tiny assert harness. Avoids a pytest dependency -- the only thing
    these tests need installed is lupa."""

    def __init__(self, title):
        self.results = []
        print(f"\n=== {title} ===")

    def section(self, label):
        print(f"\n-- {label} --")

    def eq(self, label, got, want):
        ok = got == want
        self.results.append((ok, label))
        print(f"  [{'PASS' if ok else 'FAIL'}] {label}: got {got!r}, want {want!r}")
        return ok

    def ok(self, label, condition):
        return self.eq(label, bool(condition), True)

    def summary(self):
        passed = sum(1 for ok, _ in self.results if ok)
        total = len(self.results)
        print(f"\n{'-' * 52}\n{passed}/{total} passed")
        for ok, label in self.results:
            if not ok:
                print(f"  FAILED: {label}")
        return passed == total
