"""Runs the mod's Lua tests offline: tests/*_test.lua against the real scripts/NoAICollisions.lua, engine stubbed.

Every test function gets a fresh Lua runtime: tests/stubs.lua, then the script, then the test file, which returns a
table of test functions. Needs the lupa package (pip install lupa); GitHub Actions runs this after the build
(test-command in .github/workflows/build.yml). lupa runs Lua 5.4/5.5, stricter than the game's 5.1.

    python tests/run_tests.py
"""
import glob
import os
import sys

import lupa

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCRIPT = os.path.join(ROOT, "scripts", "NoAICollisions.lua")


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def runtime(test_file):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(read(os.path.join(HERE, "stubs.lua")))
    lua.execute(read(SCRIPT))
    return lua, lua.execute(read(test_file))


def main():
    failed = 0
    total = 0
    for test_file in sorted(glob.glob(os.path.join(HERE, "*_test.lua"))):
        _, tests = runtime(test_file)
        for name in sorted(tests.keys()):
            total += 1
            _, fresh = runtime(test_file)
            try:
                fresh[name]()
                print("ok    %s.%s" % (os.path.basename(test_file)[:-4], name))
            except lupa.LuaError as err:
                failed += 1
                print("FAIL  %s.%s: %s" % (os.path.basename(test_file)[:-4], name, err))
    print("%d passed, %d failed" % (total - failed, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
