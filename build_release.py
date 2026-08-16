"""
Build the CurseForge upload zip.

CurseForge expects the archive to contain exactly one top-level folder named
after the addon, matching the .toc filename, so that unzipping into
    World of Warcraft/_retail_/Interface/AddOns/
produces AddOns/AdventureKit/AdventureKit.toc

Anything not shipped to players (tests, build scripts, git) is excluded --
a stray folder inside the addon directory is at best noise and at worst
makes the addon look broken to users browsing their AddOns folder.

    python build_release.py

Writes dist/AdventureKit-<version>.zip and verifies the result.
"""

import os
import sys
import zipfile

ADDON_NAME = "AdventureKit"
ROOT = os.path.dirname(os.path.abspath(__file__))
DIST = os.path.join(ROOT, "dist")
TOC = os.path.join(ROOT, f"{ADDON_NAME}.toc")

# Shipped to players. Everything else is deliberately left out.
INCLUDE = [
    f"{ADDON_NAME}.toc",
    "AdventureKit.lua",
    "SpeedTracker.lua",
    "README.md",
    "LICENSE",
]


def toc_version():
    with open(TOC, encoding="utf-8") as fh:
        for line in fh:
            if line.strip().startswith("## Version:"):
                return line.split(":", 1)[1].strip()
    sys.exit("No '## Version:' directive in the .toc")


def main():
    version = toc_version()
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, f"{ADDON_NAME}-{version}.zip")

    missing = [f for f in INCLUDE if not os.path.exists(os.path.join(ROOT, f))]
    if missing:
        sys.exit(f"Missing files: {', '.join(missing)}")

    if os.path.exists(out):
        os.remove(out)

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for f in INCLUDE:
            z.write(os.path.join(ROOT, f), f"{ADDON_NAME}/{f}")

    # Verify what we just wrote rather than trusting the loop above.
    with zipfile.ZipFile(out) as z:
        names = z.namelist()
        bad = z.testzip()
        if bad:
            sys.exit(f"Corrupt entry in archive: {bad}")

    roots = {n.split("/")[0] for n in names}
    if roots != {ADDON_NAME}:
        sys.exit(f"Archive must have exactly one top-level folder; got {roots}")
    if f"{ADDON_NAME}/{ADDON_NAME}.toc" not in names:
        sys.exit("Archive is missing the .toc at the expected path")
    leaked = [n for n in names if "/tests/" in n or n.endswith(".py") or ".git" in n]
    if leaked:
        sys.exit(f"Non-shipping files leaked into the archive: {leaked}")

    size = os.path.getsize(out)
    print(f"Built {out}  ({size:,} bytes)")
    print(f"Version {version} -- {len(names)} files:")
    for n in sorted(names):
        print(f"  {n}")
    print("\nStructure verified: single top-level folder, .toc present, no test/build files.")


if __name__ == "__main__":
    main()
