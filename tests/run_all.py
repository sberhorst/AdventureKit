"""Run every test module in this folder. Exits non-zero if any fail."""

import os
import sys
import importlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

MODULES = sorted(
    f[:-3] for f in os.listdir(HERE)
    if f.startswith("test_") and f.endswith(".py")
)

failed = []
for name in MODULES:
    mod = importlib.import_module(name)
    if not mod.main():
        failed.append(name)

print("\n" + "=" * 52)
if failed:
    print(f"FAILED: {', '.join(failed)}")
    sys.exit(1)
print(f"ALL GREEN ({len(MODULES)} modules)")
sys.exit(0)
