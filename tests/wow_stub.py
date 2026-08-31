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
_G.TEST = {
  auras = {}, restricted = false, prints = {}, spellNames = {},
  speed = 7.0,        -- GetUnitSpeed return; 7.0 is base run speed
  speedTaint = false, -- true => GetUnitSpeed yields a value that errors on arithmetic
}

-- A "secret number": readable, but any arithmetic on it raises. This is how
-- protected combat state behaves for addons -- the value comes back, and the
-- error only fires when you try to use it. Addons must do the retrieval AND
-- the arithmetic inside the same pcall.
_G.SECRET_NUMBER = setmetatable({}, {
  __div = function() error("attempt to perform arithmetic on a secret value") end,
  __mul = function() error("attempt to perform arithmetic on a secret value") end,
  __add = function() error("attempt to perform arithmetic on a secret value") end,
  __sub = function() error("attempt to perform arithmetic on a secret value") end,
  __lt  = function() error("attempt to compare a secret value") end,
  __le  = function() error("attempt to compare a secret value") end,
})

-- A stand-in frame.
--
-- Methods that carry state a test might reasonably assert on -- shown,
-- scale, text, checked, anchor point, scripts -- are real. Everything else
-- falls through to a no-op that returns the frame, so the addon's chained
-- UI setup runs without us having to enumerate the whole widget API.
--
-- The real state matters: with a blanket "return the frame" stub, IsShown()
-- returns a table, which is truthy, so `not frame:IsShown()` is always false
-- and any toggle test silently passes regardless of the addon's behaviour.
local stubframe
stubframe = function()
  local f = {
    _shown = true, _scale = 1, _text = "", _checked = false,
    _point = {"TOPLEFT", nil, "TOPLEFT", 0, 0}, _scripts = {},
  }
  function f:SetShown(v) self._shown = (v and true or false) return self end
  function f:Show()      self._shown = true  return self end
  function f:Hide()      self._shown = false return self end
  function f:IsShown()   return self._shown end
  function f:IsVisible() return self._shown end
  function f:SetScale(v) self._scale = v return self end
  function f:GetScale()  return self._scale end
  function f:SetText(t)  self._text = t return self end
  function f:GetText()   return self._text end
  function f:SetChecked(v) self._checked = (v and true or false) return self end
  function f:GetChecked()  return self._checked end
  function f:SetPoint(p, rel, rp, x, y)
    self._point = {p, rel, rp, x or 0, y or 0} return self
  end
  function f:GetPoint() local p = self._point return p[1], p[2], p[3], p[4], p[5] end
  function f:SetScript(k, fn) self._scripts[k] = fn return self end
  function f:GetScript(k)     return self._scripts[k] end
  function f:HasScript()      return true end
  -- Geometry returns real numbers. Addons do layout arithmetic on these
  -- (`16 / slider:GetWidth()`), and a frame-returning stub turns that into
  -- "attempt to perform arithmetic on a table value" at load time.
  function f:SetWidth(v)  self._w = v return self end
  function f:GetWidth()   return self._w or 100 end
  function f:SetHeight(v) self._h = v return self end
  function f:GetHeight()  return self._h or 20 end
  function f:SetSize(w, h) self._w, self._h = w, h return self end
  function f:GetSize()    return self:GetWidth(), self:GetHeight() end
  function f:GetLeft()    return 0 end
  function f:GetRight()   return self:GetWidth() end
  function f:GetTop()     return self:GetHeight() end
  function f:GetBottom()  return 0 end
  function f:GetCenter()  return self:GetWidth() / 2, self:GetHeight() / 2 end
  function f:GetEffectiveScale() return self._scale or 1 end
  function f:GetFrameLevel()     return 1 end
  function f:GetStringWidth()    return 50 end
  function f:GetStringHeight()   return 12 end
  function f:GetNumPoints()      return 1 end
  function f:GetValue()          return self._value or 0 end
  function f:SetValue(v)         self._value = v return self end
  function f:GetMinMaxValues()   return 0, 100 end
  function f:GetThumbTexture()   return stubframe() end
  function f:GetFont()           return "Fonts\\FRIZQT__.TTF", 12, "" end
  function f:GetObjectType()     return "Frame" end
  function f:CreateFontString() return stubframe() end
  function f:CreateTexture()    return stubframe() end
  function f:CreateLine()       return stubframe() end
  -- Unknown METHODS fall through to a no-op that returns the frame, so the
  -- addon's chained UI setup runs without us enumerating the whole widget
  -- API. Unknown FIELDS must come back nil.
  --
  -- Returning the no-op for every key made `if frame.myCustomFlag then`
  -- always true, because a function is truthy. That silently defeated every
  -- "have I already hooked this?" guard an addon stashes on a frame --
  -- TryHook saw its own sentinel already set and never installed the hook,
  -- and a cached-overlay lookup returned a function instead of nil. Both
  -- read as passing tests over code that never ran.
  --
  -- Blizzard's frame methods are PascalCase and the fields addons stash on
  -- frames are not, so the initial capital is the split.
  return setmetatable(f, {__index = function(_, key)
    if type(key) == "string" and key:match("^%u") then
      return function(s) return s end
    end
    return nil
  end})
end
_G.stubframe = stubframe

-- Every frame the addon creates is recorded, so a test can dispatch an
-- event to all of them the way the client does, instead of reaching for one
-- particular frame the addon happens to keep in a local.
TEST.frames = {}
-- A NAMED frame is published as a global by the client, and addons rely on
-- that to find each other's frames. Dropping the name meant any assertion
-- reaching a frame by its global name failed even though the addon was
-- doing the right thing.
CreateFrame  = function(frameType, name, parent, template)
                 local f = stubframe()
                 table.insert(TEST.frames, f)
                 if type(name) == "string" and name ~= "" then
                   _G[name] = f
                 end
                 return f
               end
UIParent     = stubframe()
GameTooltip  = stubframe()
strtrim      = function(s, chars) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
strsplit     = function(sep, s) return s end
wipe         = function(t) for k in pairs(t) do t[k] = nil end return t end
unpack       = unpack or table.unpack
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
GetUnitSpeed         = function()
                         if TEST.speedTaint then return SECRET_NUMBER end
                         return TEST.speed
                       end
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


def load_addon(files, exports=(), extra_lua="", addon_name=None):
    """Load addon .lua files under the stub.

    files   -- filenames relative to the addon root, in TOC order. Paths may
               use the .toc's backslashes. Non-.lua entries (embeds.xml) are
               skipped: XML-included libraries are stubbed, not executed.
    exports -- names of addon *locals* to re-expose on _G as T_<name>, since
               Lua locals are otherwise unreachable from the harness.

    Each file is loaded as its own chunk and called with (addonName, addon),
    which is what WoW does. That matters twice over: files get their own
    local scope rather than silently sharing one, and the common
    `local addonName, addon = ...` namespace idiom actually receives its
    arguments instead of nil.
    """
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)
    if extra_lua:
        lua.execute(extra_lua)

    if addon_name is None:
        addon_name = os.path.basename(ADDON_ROOT).replace("-repo", "")

    # Shared private namespace, the second vararg WoW hands every addon file.
    # Also published as _G.ADDON_NS so tests can call methods the addon hangs
    # off it (`function addon:parseRealID(...)`), which are otherwise
    # unreachable -- they live on a table no global points at.
    shared = lua.eval("{}")
    lua.globals().ADDON_NS = shared

    run_chunk = lua.eval(
        "function(src, chunkname, addonName, addonTable)"
        "  local fn, err = load(src, chunkname)"
        "  if not fn then error(chunkname .. ': ' .. tostring(err), 0) end"
        "  return fn(addonName, addonTable)"
        "end"
    )

    # Only assign an export from the chunk that actually defines it, so a
    # later file cannot blank out an earlier file's symbol with nil.
    tail = "\n".join(
        f"if {n} ~= nil then _G.T_{n} = {n} end" for n in exports
    )

    for name in files:
        if not name.lower().endswith(".lua"):
            continue
        rel = name.replace("\\", os.sep).replace("/", os.sep)
        path = os.path.join(ADDON_ROOT, rel)
        with open(path, encoding="utf-8") as fh:
            source = fh.read()
        run_chunk(source + "\n" + tail + "\n", "@" + name, addon_name, shared)

    return lua


def fire_event(lua, event, *args):
    """Dispatch an event to every frame with an OnEvent script.

    This is what the client does: it does not know or care which frame an
    addon kept in which local. Driving events this way means a test does not
    have to export a frame just to reach its handler, and it exercises the
    real registration path.

    Errors from handlers propagate, so a test can assert an event completes
    cleanly -- which is the whole point when the failure being guarded
    against is "the addon raised during ADDON_LOADED".
    """
    frames = lua.globals().TEST.frames
    for frame in list(frames.values()):
        handler = frame.GetScript(frame, "OnEvent")
        if handler is not None:
            handler(frame, event, *args)


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
