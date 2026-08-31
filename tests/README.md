# Tests

Runs AdventureKit's actual Lua against a stubbed WoW API, outside the game.

```bash
pip install lupa
python tests/run_all.py
```

Exits `0` if everything passes, `1` if anything fails. No other dependencies —
`lupa` embeds a real Lua interpreter in Python, so these tests execute the
addon's real source rather than reasoning about it.

## Why this exists

Nothing here has ever broken because a Lua function was wrong internally. It
breaks at the seam with Blizzard's API, and that seam moves every patch.

Patch **12.1.0 (Midnight)** is the worked example. Blizzard made aura data
*secret* during combat, boss encounters, Mythic+ and PvP: every `C_UnitAuras`
call reaching aura data **by index, slot or instance ID** now raises a Lua
error when an addon makes it.

AdventureKit read player buffs by index, inside a `pcall`, and returned `nil`
both when the call was blocked and when the slot was simply empty. Two very
different facts, one value. The result would have been `HasFlask`/`HasFood`
returning `false` for the entire duration of every pull — the HUD flashing
*No Flask / No Food* at a fully buffed character, in exactly the content the
addon is built for.

Nothing about that is visible in a diff, and the addon still loaded fine.
`tests/test_auras.py` section 3 is the guard against it returning.

## Layout

| File | What it covers |
|---|---|
| `wow_stub.py` | The fake Blizzard API, plus `load_addon()` and a small assert helper |
| `test_smoke.py` | Every Lua file in the `.toc` parses and executes; TOC Interface is well-formed; `ADDON_VERSION` matches the TOC `Version` |
| `test_auras.py` | Flask / food / raid-buff detection, with and without 12.1 secret auras |
| `ak_stub.py` | AdventureKit's own API surface: specialization lookup, pet state, combat lockdown |
| `test_pets.py` | Which specs are alerted for a pet, temporary summons, unknown spec, the master alert switch |
| `run_all.py` | Runs every `test_*.py` here |

## Writing a test

`load_addon()` takes the Lua files in TOC order and a list of addon **locals**
to re-expose (Lua locals are otherwise unreachable from outside the file):

```python
from wow_stub import load_addon, set_auras, Check

lua = load_addon(["AdventureKit.lua"], exports=["HasFlask"])
g = lua.globals()

set_auras(lua, [("Flask of Tempered Versatility", 999001)])
g.TEST.restricted = True          # simulate 12.1 secret auras
assert g.T_HasFlask() is True     # exported local -> T_<name>
```

`g.TEST` is the control surface: `auras`, `restricted`, `spellNames`, and
`prints` (everything the addon sent to chat).

## Two rules that make this worth running

1. **Model the new API behaviour in the stub, not the old one.** The stub is
   only useful if it lies the way the current patch lies.
2. **Prove the test can fail.** Re-introduce the bug, watch the suite go red,
   then restore. A guard that has never gone red is decoration — this suite
   was checked that way, and section 3 correctly fails when the 12.1 fix is
   reverted.

## Porting this to the other addons

`wow_stub.py` is addon-agnostic apart from `ADDON_ROOT`, which resolves to the
repo containing `tests/`. Copy the folder into Socialite / SpeedTracker /
ElitistsToolkit, point `test_smoke.py` at that addon's `.toc`, and add stubs
for whatever APIs it touches that aren't here yet.

## Two fixes carried in from ElitistsToolkit

`wow_stub.py` is shared across AdventureKit, ElitistsToolkit, SpeedTracker and
Socialite. Two faults were found in it while writing ElitistsToolkit's tests,
and the corrected file has been copied here.

1. **`stubframe` answered every unknown key with a no-op function.** Functions
   are truthy in Lua, so any `if frame.mySentinel then` guard saw its own flag
   already set. Hooks were never installed and the tests went green over code
   that never ran. Frame *methods* are PascalCase and stashed *fields* are not,
   so the initial capital is now the split.
2. **`CreateFrame` discarded the frame's name.** The client publishes a named
   frame as a global, and addons rely on that, so nothing was reachable by the
   name it is actually given.

Neither changed AdventureKit's existing results, which were re-run before and
after the swap. They matter for what can be tested from here on.
