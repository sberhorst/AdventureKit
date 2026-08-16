"""
Aura-reading tests for AdventureKit.

These exist because of patch 12.1.0 (Midnight). Blizzard made aura data
"secret" during combat, boss encounters, Mythic+ and PvP: any C_UnitAuras
call that reaches aura data by index, slot or instance ID now raises a Lua
error when an addon makes it.

The addon read player buffs by index. Worse, the old helper pcall-wrapped
that call and returned nil BOTH when the call was blocked AND when the slot
was simply empty -- two very different facts collapsed into one value. So
HasFlask/HasFood returned false for the whole of every pull, and the HUD
would flash "No Flask / No Food" at a fully buffed character.

Section 3 below is the guard against that ever coming back. It is the test
that matters; the rest is scaffolding around it.
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wow_stub import load_addon, set_auras, Check  # noqa: E402

# A Midnight-era flask whose spell ID is deliberately NOT in FLASK_BUFF_IDS,
# so these tests exercise the name-matching path the addon actually relies on.
FLASK = ("Flask of Tempered Versatility", 999001)
FOOD = ("Well Fed", 999002)
KNOWN_ID_FLASK = ("Flask of Alchemical Chaos", 432021)  # IS in FLASK_BUFF_IDS


def main():
    c = Check("AdventureKit :: aura reads under 12.1 Secret Auras")

    lua = load_addon(
        ["AdventureKit.lua"],
        exports=["HasFlask", "HasFood", "ScanBuffs", "SpellName", "UnitHasAuraNamed"],
    )
    g = lua.globals()
    T = g.TEST
    print("  [PASS] AdventureKit.lua parsed and loaded")

    c.section("1. Out of combat, auras readable")
    T.restricted = False
    set_auras(lua, [FLASK, FOOD])
    c.eq("HasFlask with flask up", g.T_HasFlask(), True)
    c.eq("HasFood with food up", g.T_HasFood(), True)

    c.section("2. Out of combat, nothing up")
    set_auras(lua, [])
    c.eq("HasFlask bare", g.T_HasFlask(), False)
    c.eq("HasFood bare", g.T_HasFood(), False)

    c.section("3. REGRESSION GUARD: buffed, then auras go secret at the pull")
    set_auras(lua, [FLASK, FOOD])
    g.T_HasFlask()
    g.T_HasFood()          # pre-pull reading, taken out of combat
    T.restricted = True    # boss pull: aura data becomes secret
    c.eq("HasFlask mid-encounter must NOT false-alarm", g.T_HasFlask(), True)
    c.eq("HasFood mid-encounter must NOT false-alarm", g.T_HasFood(), True)

    c.section("4. Genuinely unbuffed, then auras go secret")
    T.restricted = False
    set_auras(lua, [])
    g.T_HasFlask()
    g.T_HasFood()
    T.restricted = True
    c.eq("HasFlask stays false", g.T_HasFlask(), False)
    c.eq("HasFood stays false", g.T_HasFood(), False)

    c.section("5. ScanBuffs separates 'restricted' from 'empty'")
    T.restricted = True
    ok, _ = g.T_ScanBuffs("player")
    c.eq("restricted -> ok=false", ok, False)
    T.restricted = False
    set_auras(lua, [])
    ok, lst = g.T_ScanBuffs("player")
    c.eq("empty -> ok=true", ok, True)
    c.eq("empty -> zero entries", len(list(lst.values())), 0)

    c.section("6. Spell-ID fast path still resolves mid-combat")
    set_auras(lua, [KNOWN_ID_FLASK])
    g.T_HasFlask()
    T.restricted = True
    c.eq("known-ID flask readable while secret", g.T_HasFlask(), True)

    c.section("7. Raid buffs resolve by localised spell name")
    T.restricted = True
    T.spellNames[1459] = "Arcane Intellect"
    set_auras(lua, [("Arcane Intellect", 1459)])
    c.eq("SpellName(1459)", g.T_SpellName(1459), "Arcane Intellect")
    c.eq("present buff found while secret",
         g.T_UnitHasAuraNamed("player", "Arcane Intellect"), True)
    c.eq("absent buff not found",
         g.T_UnitHasAuraNamed("player", "Battle Shout"), False)

    c.section("8. Non-English client: unresolved name yields no false alarm")
    c.eq("SpellName(6673) uncached", g.T_SpellName(6673), None)

    return c.summary()


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
