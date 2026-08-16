"""
Build the CurseForge upload zip.

CurseForge expects the archive to contain exactly one top-level folder named
after the addon and matching the .toc filename, so that unzipping into
    World of Warcraft/_retail_/Interface/AddOns/
produces AddOns/<Addon>/<Addon>.toc

The shipped file list is read from the .toc rather than hardcoded here.
Hardcoding it means adding a Lua file to the addon and silently not shipping
it -- the addon then fails only on a clean install, which is the worst place
to find out. Anything not shipped to players (tests, build tooling, git) is
excluded and the script fails if any of it leaks in.

    python build_release.py

Writes dist/<Addon>-<version>.zip and verifies the result.
"""

import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
DIST = os.path.join(ROOT, "dist")

# Shipped alongside the .toc and everything it lists, when present.
EXTRA_FILES = ["README.md", "LICENSE", "LICENSE.txt", "CHANGELOG.md"]

# Never shipped, whatever the .toc says.
BLOCKED = re.compile(r"(^|/)(tests?|dist|\.git|__pycache__)(/|$)|\.pyc?$")


def find_toc():
    tocs = [f for f in os.listdir(ROOT) if f.endswith(".toc")]
    if len(tocs) != 1:
        sys.exit(f"Expected exactly one .toc in {ROOT}, found {tocs}")
    return tocs[0]


def parse_toc(path):
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


def referenced_by_xml(xml_rel):
    """Files an .xml pulls in, so embedded libraries actually ship."""
    out, path = [], os.path.join(ROOT, xml_rel.replace("\\", os.sep))
    if not os.path.exists(path):
        return out
    with open(path, encoding="utf-8", errors="replace") as fh:
        body = fh.read()
    # Strip XML comments first. Ace3 ships disabled includes commented out
    # (AceConfigDropdown), and matching inside a comment makes the build
    # demand a file that is deliberately absent. Packager markers such as
    # <!--@no-lib-strip@--> are standalone comments, so removing comments
    # drops the markers and leaves the real includes between them intact.
    body = re.sub(r"<!--.*?-->", "", body, flags=re.S)
    base = os.path.dirname(xml_rel.replace("\\", os.sep))
    for ref in re.findall(r'file=["\']([^"\']+)["\']', body):
        rel = os.path.normpath(os.path.join(base, ref.replace("\\", os.sep)))
        out.append(rel)
        if rel.lower().endswith(".xml"):
            out.extend(referenced_by_xml(rel))
    return out


def main():
    toc_name = find_toc()
    addon = toc_name[:-4]
    directives, listed = parse_toc(os.path.join(ROOT, toc_name))

    override = None
    for i, a in enumerate(sys.argv[1:]):
        if a == "--version" and i + 2 <= len(sys.argv[1:]):
            override = sys.argv[i + 2]
        elif a.startswith("--version="):
            override = a.split("=", 1)[1]

    version = directives.get("Version", "")
    if not version:
        sys.exit("No '## Version:' directive in the .toc")

    token = re.fullmatch(r"@[\w-]+@", version)
    if token and not override:
        sys.exit(
            f"Version is the packager token {version}. This addon is normally "
            f"built by the CurseForge packager, which substitutes it at release "
            f"time -- a hand-built zip would ship the literal token.\n\n"
            f"Use the packager, or pass an explicit version to build anyway:\n"
            f"    python build_release.py --version 9.2.0-fork.1"
        )
    version_token_text = version if token else None
    if override:
        version = override

    wanted = [toc_name]
    for entry in listed:
        rel = os.path.normpath(entry.replace("\\", os.sep))
        wanted.append(rel)
        if rel.lower().endswith(".xml"):
            wanted.extend(referenced_by_xml(entry))
    for extra in EXTRA_FILES:
        if os.path.exists(os.path.join(ROOT, extra)):
            wanted.append(extra)

    seen, files = set(), []
    for f in wanted:
        key = f.replace("\\", "/").lower()
        if key not in seen:
            seen.add(key)
            files.append(f)

    missing = [f for f in files if not os.path.exists(os.path.join(ROOT, f))]
    if missing:
        sys.exit(f"Listed in the .toc but missing on disk: {', '.join(missing)}")

    leaked = [f for f in files if BLOCKED.search(f.replace("\\", "/"))]
    if leaked:
        sys.exit(f"Non-shipping files matched: {leaked}")

    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, f"{addon}-{version}.zip")
    if os.path.exists(out):
        os.remove(out)

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for f in files:
            arc = f"{addon}/" + f.replace(os.sep, "/")
            if f == toc_name and token:
                # The working-tree .toc must keep @project-version@ for the
                # packager, but shipping that literal would show the raw token
                # in the player's AddOns list. Substitute it in the archived
                # copy only, leaving the file on disk untouched.
                body = open(os.path.join(ROOT, f), encoding="utf-8").read()
                body = body.replace(version_token_text, version)
                z.writestr(arc, body)
            else:
                z.write(os.path.join(ROOT, f), arc)

    # Verify what was written rather than trusting the loop above.
    with zipfile.ZipFile(out) as z:
        names = z.namelist()
        bad = z.testzip()
    if bad:
        sys.exit(f"Corrupt entry in archive: {bad}")

    roots = {n.split("/")[0] for n in names}
    if roots != {addon}:
        sys.exit(f"Archive must have exactly one top-level folder; got {roots}")
    if f"{addon}/{toc_name}" not in names:
        sys.exit("Archive is missing the .toc at the expected path")
    leaked = [n for n in names if BLOCKED.search(n)]
    if leaked:
        sys.exit(f"Non-shipping files leaked into the archive: {leaked}")

    print(f"Built {out}  ({os.path.getsize(out):,} bytes)")
    print(f"{addon} {version} -- Interface {directives.get('Interface', '?')} "
          f"-- {len(names)} files:")
    for n in sorted(names):
        print(f"  {n}")
    print("\nVerified: single top-level folder, .toc present, "
          "no test or build files.")


if __name__ == "__main__":
    main()
