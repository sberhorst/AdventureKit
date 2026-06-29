# AdventurerKit

**v1.0.0 | Author: morphe#11766 | WoW Retail (The War Within)**

A zero-dependency quality-of-life addon for active dungeon and raid players.

---

## Features

### 1. Auto-Repair
Automatically repairs all equipped gear when you open a repair vendor.
- Optionally uses Guild Bank gold first
- Reports cost to chat
- Warns if you're short on gold

### 2. Auto-Sell Greys
When any merchant window opens, all Poor quality (grey) items in your bags are sold automatically.
- Quest items are detected and skipped
- Reports total gold earned to chat

### 3. Instance Entry Alerts
On entering a dungeon or raid, alerts you to:
- **Missing flask** — checks for any active flask buff
- **No pet out** — for Hunter, Warlock, Unholy DK
- **Missing raid-wide buff** — checks your class-specific buff (Mark of the Wild, Battle Shout, Arcane Intellect, etc.)

Alerts fire 3 seconds after entry to let buffs settle post-loading-screen.

### 4. Durability Warnings
Warns in chat when any equipped gear slot drops below your configured threshold (default: 50%).
- Fires on zone change and world entry
- Throttled to avoid spam (max once per 60s per zone)
- Threshold configurable via `/ak threshold <number>` or the options panel

### 5. Movement Speed Display (SpeedTracker)
Embedded SpeedTracker v1.9.1 — lightweight draggable frame showing movement speed as % of base.
- Combat-safe via AbbreviateNumbers() C-level workaround (WoW 12.0+)
- Right-click to lock/unlock position
- Configure via `/speed` or the options panel

---

## Slash Commands

| Command | Description |
|---|---|
| `/ak` | Show help |
| `/ak status` | Show all current settings |
| `/ak repair` | Toggle auto-repair |
| `/ak guild` | Toggle guild bank repair |
| `/ak sell` | Toggle auto-sell greys |
| `/ak alerts` | Toggle instance alerts |
| `/ak flask` | Toggle flask alert |
| `/ak pet` | Toggle pet alert |
| `/ak buffs` | Toggle raid buff alert |
| `/ak durability` | Toggle durability warning |
| `/ak threshold <1-100>` | Set durability warn threshold |
| `/ak check` | Run durability check now |
| `/speed` | Open SpeedTracker options |
| `/speed lock` | Toggle speed frame lock |
| `/speed reset` | Reset speed frame position |

---

## Options Panel

ESC → Interface → AddOns → **AdventurerKit**
SpeedTracker appears as a nested sub-category.

---

## Supported Classes for Raid Buff Alerts

| Class | Buff |
|---|---|
| Druid | Mark of the Wild |
| Warrior | Battle Shout |
| Death Knight | Horn of Winter |
| Mage | Arcane Intellect |
| Priest | Power Word: Fortitude |
| Paladin | Blessing of Might / Kings |
| Monk | Legacy of the Emperor |
| Evoker | Blessing of the Bronze |

---

## Installation

1. Extract the `AdventurerKit` folder into:
   `World of Warcraft/_retail_/Interface/AddOns/`
2. Launch WoW and enable **AdventurerKit** in the AddOns list.
3. The SpeedTracker sub-module activates automatically — no separate installation needed.

---

## Notes

- Single `SavedVariables` block (`AdventurerKitDB`) covers all features including SpeedTracker
- No external libraries required
- Compatible with WoW Retail 12.x (The War Within)
