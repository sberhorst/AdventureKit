"""
Guard against calling Blizzard APIs that the current patch has removed,
renamed, or restricted.

Addons do not usually break because their own logic is wrong. They break
because the game moved underneath them, and the failure is invisible until
someone logs in. This scans the addon's own Lua for known-dead API names so
patch-day breakage is a red test rather than a bug report.

Three severities:

  REMOVED     calling it is a nil-index error. Fails the suite.
  RENAMED     the old name is gone; there is a direct replacement. Fails.
  RESTRICTED  still callable, but it now errors or returns secrets in some
              contexts. Reported, not failed -- using it can be correct if
              the call sites handle the restriction (AdventureKit's
              ScanBuffs does exactly that, deliberately).

Comments are stripped before scanning, so discussing a dead API in a comment
is not a failure -- only calling it is.

Update the tables below when a new patch lands. That edit is the point of
the file: it turns "read the patch notes and hope" into a check that runs.
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wow_stub import Check, ADDON_ROOT  # noqa: E402

PATCH = "12.1.0 (Midnight)"

# Removed outright in 12.1.0.
REMOVED = [
    "BNGetFriendInviteInfo",
    "BNSendVerifiedBattleTagInvite",
    "CanSurrenderArena",
    "CancelItemTempEnchantment",
    "C_DyeColor.GetDyeColorForItem",
    "C_DyeColor.GetDyeColorForItemLocation",
    "C_Housing.IsInsideOwnHouse",
    "C_HousingLayout.GetNumFloors",
    "C_Ping.GetContextualPingTypeForUnit",
    "C_PvP.JoinRandomTrainingGround",
    "C_RecruitAFriend.IsEnabled",
    "C_SuperTrack.GetNextWaypointForMap",
    "C_UnitAuras.TriggerPrivateAuraShowDispelType",
    "GetInspectSpecialization",
    "GetInventorySlotInfo",
    "GetWeaponEnchantInfo",
    "SetTableSecurityOption",
]

# Old name -> replacement.
RENAMED = {
    "UIParentLoadAddOn": "LoadAddOnWithErrorHandling",
    "CanAccessObject": "FrameScriptObject:CanBeAccessedInContext",
    "C_UnitAuras.AddPrivateAuraAppliedSound": "C_UnitAuras.AddAuraSound",
    "C_UnitAuras.RemovePrivateAuraAppliedSound": "C_UnitAuras.RemoveAuraSound",
    "getglobal": "_G[name]",
    "setglobal": "_G[name] = value",
}

# Still present, but constrained. Reported for review, not failed.
RESTRICTED = {
    "C_UnitAuras.GetAuraDataByIndex": "errors while auras are secret; prefer spell ID/name",
    "C_UnitAuras.GetBuffDataByIndex": "errors while auras are secret; prefer spell ID/name",
    "C_UnitAuras.GetDebuffDataByIndex": "errors while auras are secret; prefer spell ID/name",
    "C_UnitAuras.GetAuraDataBySlot": "errors while auras are secret; prefer spell ID/name",
    "C_UnitAuras.GetAuraDataByAuraInstanceID": "errors while auras are secret",
    "SecureAuraHeaderTemplate": "removed from Mainline; migrate to AuraContainer",
}

# Directories never scanned: third-party code we do not control.
SKIP_DIRS = {"vendor", "libs", "Libs", ".git", "tests", "dist", "__pycache__"}


def strip_lua_comments(src):
    src = re.sub(r"--\[(=*)\[.*?\]\1\]", "", src, flags=re.S)  # block comments
    src = re.sub(r"--[^\n]*", "", src)                          # line comments
    return src


def addon_lua_files():
    out = []
    for root, dirs, names in os.walk(ADDON_ROOT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for n in names:
            if n.endswith(".lua"):
                out.append(os.path.join(root, n))
    return sorted(out)


def find(name, src):
    """Locate a call to `name`. A dotted name matches literally; a bare name
    must not be preceded by a dot, so C_PaperDollInfo.GetInventorySlotInfo
    does not read as a call to the removed global GetInventorySlotInfo."""
    if "." in name:
        pattern = re.escape(name)
    else:
        pattern = r"(?<![.:\w])" + re.escape(name) + r"(?![\w])"
    return re.search(pattern, src) is not None


def main():
    c = Check(f"API contract :: removed/renamed in patch {PATCH}")

    files = addon_lua_files()
    c.ok("found addon Lua to scan", files)
    print(f"        scanning {len(files)} file(s), excluding {sorted(SKIP_DIRS)}")

    sources = {}
    for path in files:
        with open(path, encoding="utf-8") as fh:
            sources[os.path.relpath(path, ADDON_ROOT)] = strip_lua_comments(fh.read())

    c.section("Removed APIs")
    for name in REMOVED:
        hits = [f for f, src in sources.items() if find(name, src)]
        c.ok(f"{name} not called{' -- found in ' + ', '.join(hits) if hits else ''}",
             not hits)

    c.section("Renamed APIs")
    for name, replacement in RENAMED.items():
        hits = [f for f, src in sources.items() if find(name, src)]
        label = f"{name} not called"
        if hits:
            label += f" -- found in {', '.join(hits)}; use {replacement}"
        c.ok(label, not hits)

    c.section("Restricted APIs (reported, not failed)")
    any_restricted = False
    for name, note in RESTRICTED.items():
        hits = [f for f, src in sources.items() if find(name, src)]
        if hits:
            any_restricted = True
            print(f"  [NOTE] {name} used in {', '.join(hits)}")
            print(f"         {note}")
    if not any_restricted:
        print("  (none)")

    return c.summary()


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
