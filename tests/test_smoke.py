"""
Smoke test: every .lua file listed in the .toc parses and executes cleanly.

Cheap but not trivial -- it catches syntax errors, a nil global introduced by
a refactor, and any load-time call into an API Blizzard has removed. Those
are the failures that stop the addon dead at login, and they are exactly the
class of breakage a patch introduces.

It also checks the .toc Interface number is well-formed and matches the
version the addon reports, so a TOC bump can't drift from the code.
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wow_stub import load_addon, Check, ADDON_ROOT  # noqa: E402

TOC = os.path.join(ADDON_ROOT, "AdventureKit.toc")


def parse_toc(path):
    """Return (directives, lua_files) from a .toc."""
    directives, files = {}, []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            if line.startswith("##"):
                key, _, value = line[2:].partition(":")
                directives[key.strip()] = value.strip()
            elif not line.startswith("#"):
                files.append(line)
    return directives, files


def main():
    c = Check("AdventureKit :: smoke")

    c.section("TOC")
    directives, files = parse_toc(TOC)

    interface = directives.get("Interface", "")
    c.ok("Interface is a 6-digit build number", re.fullmatch(r"\d{6}", interface))
    print(f"        Interface: {interface}")

    toc_version = directives.get("Version", "")
    c.ok("Version present", toc_version)

    c.ok("declares at least one Lua file", files)
    for f in files:
        c.ok(f"{f} exists on disk", os.path.exists(os.path.join(ADDON_ROOT, f)))

    c.section("Lua loads")
    try:
        lua = load_addon(files, exports=["ADDON_VERSION"])
        c.ok("all TOC Lua files loaded under the stub", True)
    except Exception as exc:  # noqa: BLE001
        c.ok(f"all TOC Lua files loaded under the stub -- {exc}", False)
        return c.summary()

    c.section("Version consistency")
    code_version = lua.globals().T_ADDON_VERSION
    c.eq("ADDON_VERSION matches TOC Version", code_version, toc_version)

    return c.summary()


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
