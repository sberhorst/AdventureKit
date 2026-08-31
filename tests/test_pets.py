"""
Pet alerts: whose spec actually keeps a pet, and what counts as one.

The bug this guards, in the reporter's words: a Blood Death Knight got a
"No pet summoned!" alert they could not act on. Blood has no permanent pet.
What it does have is Raise Dead -- a temporary, uncontrollable ghoul -- which
occupied the pet slot for under a minute and made the alert flicker on and
off while offering nothing the player could do about it.

Two separate faults produced that:

1. The pet table was keyed on CLASS, so every Death Knight was treated as
   needing a pet. Meanwhile the options UI told the player "MM Hunters and
   non-Unholy DKs excluded automatically" -- a rule written in the interface
   and enforced nowhere. The UI was not describing the code; it was
   describing an intention.

2. Any unit in the pet slot counted as "your pet is out", so a temporary
   summon silenced a real missing-pet alert for the length of its cooldown.

Section 4 is the master alert switch: one control that has to reach every
alert, including the pet death alert, which deliberately ignores every other
suppression rule and would otherwise be the one alert a player cannot turn
off.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wow_stub import load_addon, fire_event, Check  # noqa: E402
from ak_stub import EXTRA_LUA  # noqa: E402

EXPORTS = ["NeedsPet", "PetStatus", "AlertsAllowed", "PET_SPECS"]

# spec ID -> (label, does this spec keep a permanent pet?)
SPECS = [
    (250, "Blood DK",        False),
    (251, "Frost DK",        False),
    (252, "Unholy DK",       True),
    (253, "BM Hunter",       True),
    (254, "MM Hunter",       False),
    (255, "Survival Hunter", True),
    (265, "Affliction",      True),
    (266, "Demonology",      True),
    (267, "Destruction",     True),
    (62,  "Arcane Mage",     False),
    (63,  "Fire Mage",       False),
    (64,  "Frost Mage",      True),
]


def boot(spec_id=250, spec_api="modern", extra=""):
    """Load AdventureKit with the player in a given specialization.

    ADDON_LOADED is fired, not skipped: the addon's saved-variable defaults
    are applied inside that handler, and the file-local `db` every alert
    checks is assigned there too. Loading the file without it leaves the
    addon in a state it is never in at runtime.
    """
    prelude = (
        EXTRA_LUA
        + f'\nTEST.specAPI = "{spec_api}"\nTEST.specIndex = {spec_id}\n'
        + "TEST.applySpecAPI()\n"
        + extra
    )
    lua = load_addon(["AdventureKit.lua"], exports=EXPORTS, extra_lua=prelude)
    fire_event(lua, "ADDON_LOADED", "AdventureKit")
    return lua, lua.globals()


def main():
    c = Check("AdventureKit :: pet alerts by specialization")

    # -----------------------------------------------------------------
    c.section("1. Only specs with a permanent pet are alerted")

    for spec_id, label, want in SPECS:
        lua, g = boot(spec_id=spec_id)
        c.eq(f"{label} needs a pet", g.T_NeedsPet(), want)

    # The reported bug, stated as its own assertion so a regression names it.
    lua, g = boot(spec_id=250)
    c.ok("REGRESSION: Blood DK is never asked to summon a pet",
         g.T_NeedsPet() is False)

    # -----------------------------------------------------------------
    c.section("2. A temporary summon is not a pet")

    # Unholy: genuinely needs a pet. Ghoul out and controllable.
    lua, g = boot(spec_id=252,
                  extra="TEST.petExists = true\nTEST.petHealth = 100\n")
    c.eq("controllable pet reads as alive", g.T_PetStatus(), "alive")

    # Same spec, same "pet exists", but it is Army of the Dead: no pet action
    # bar. Counting it would silence a real missing-pet alert for a minute.
    lua, g = boot(spec_id=252,
                  extra="TEST.petExists = true\nTEST.petHealth = 100\n"
                        "TEST.petBar = false\n")
    c.eq("temporary uncontrollable summon does not count as a pet",
         g.T_PetStatus(), "none")

    # No pet at all.
    lua, g = boot(spec_id=252)
    c.eq("no pet reads as none", g.T_PetStatus(), "none")

    # A dead pet is still a pet -- distinct from having none, because the
    # advice differs: resurrect versus summon.
    lua, g = boot(spec_id=252,
                  extra="TEST.petExists = true\nTEST.petHealth = 0\n"
                        "TEST.petDead = true\n")
    c.eq("dead pet is reported as dead, not missing", g.T_PetStatus(), "dead")

    # -----------------------------------------------------------------
    c.section("3. Unknown spec stays silent rather than guessing")

    lua, g = boot(spec_api="none")
    c.ok("no spec API: no pet alert", g.T_NeedsPet() is False)

    # ...and the silence must not be cached, or a player who logs in before
    # spec data arrives would never get a pet alert for the whole session.
    lua, g = boot(spec_id=253, spec_api="none")
    c.ok("silence while unknown", g.T_NeedsPet() is False)
    lua.execute('TEST.specAPI = "modern"\nTEST.applySpecAPI()\n')
    c.ok("answers correctly once the spec becomes readable", g.T_NeedsPet())

    c.section("3b. Spec lookup works on both API shapes")
    for api in ("modern", "legacy"):
        lua, g = boot(spec_id=253, spec_api=api)
        c.ok(f"BM Hunter detected via {api} API", g.T_NeedsPet())
        lua, g = boot(spec_id=250, spec_api=api)
        c.ok(f"Blood DK excluded via {api} API", g.T_NeedsPet() is False)

    # -----------------------------------------------------------------
    c.section("4. Master alert switch")

    lua, g = boot()
    db = g.AdventureKitDB
    c.ok("alerts on by default", db.alertsEnabled)
    c.ok("AlertsAllowed true when enabled", g.T_AlertsAllowed())

    db.alertsEnabled = False
    c.ok("AlertsAllowed false when the master switch is off",
         g.T_AlertsAllowed() is False)

    # Individual toggles keep their own values, so turning the master switch
    # back on restores the player's configuration instead of resetting it.
    c.ok("individual toggles are untouched by the master switch",
         db.alertFlask and db.alertPet)
    db.alertsEnabled = True
    c.ok("re-enabling restores alerts", g.T_AlertsAllowed())

    # Combat muting is a separate axis and must still work.
    g.TEST.inCombat = True
    db.muteInCombat = True
    c.ok("combat muting still suppresses independently",
         g.T_AlertsAllowed() is False)

    return c.summary()


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
