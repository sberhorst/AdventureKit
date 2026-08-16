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
