# Changelog

## 2.5.0 — 2026-08-30

### New

- **Master alert switch.** "Enable alerts" at the top of the options panel,
  and `/ak alerts`, turn every alert on or off in one place — including the
  on-screen HUD and the pet death alert, which ignores every other
  suppression setting and would otherwise be the one alert you could not
  silence. Individual toggles keep their own settings while it is off, so
  turning it back on restores your configuration rather than resetting it.
  (`/ak alerts` was already listed in the README; it had never existed in
  the addon.)

### Fixed

- **Pet alerts now read your specialization, not your class.** Every Death
  Knight was told "No pet summoned!", including Blood, which has no
  permanent pet to summon — an alert with nothing the player could do about
  it. The options panel has always said "MM Hunters and non-Unholy DKs
  excluded automatically"; that rule was written in the interface and
  enforced nowhere. It is now enforced.

  Alerts: BM and Survival Hunter, all Warlock specs, Unholy Death Knight,
  Frost Mage. Silent: Marksmanship Hunter, Blood and Frost Death Knight,
  Arcane and Fire Mage.

- **A temporary summon no longer counts as your pet.** Raise Dead and Army
  of the Dead occupy the pet slot for under a minute and give you no pet
  action bar. They were being read as "your pet is out", which made the
  alert flicker on and off for Death Knights and could mask a genuinely
  missing pet for an Unholy DK with Army up.

- **Changing specialization takes effect immediately.** Whether you need a
  pet is cached, and that cache is now cleared on a spec change — a Death
  Knight swapping Blood to Unholy goes from "no pet expected" to "pet
  required" without a reload.

### Notes

Earlier releases predate this changelog.
