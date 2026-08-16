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

    version = directives.get("Version", "")
    if not version:
        sys.exit("No '## Version:' directive in the .toc")
    if re.fullmatch(r"@[\w-]+@", version):
        sys.exit(
            f"Version is the packager token {version}. This addon is built by "
            f"the CurseForge packager, which substitutes it at release time -- "
            f"a hand-built zip would ship the literal token. Use the packager."
        )

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
