#!/usr/bin/env python3
"""
Python wrapper for scripts/sync_integration_branches.ts.
Delegates directly to the canonical TypeScript implementation via Bun.
"""
import os
import sys
import subprocess

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TS_SCRIPT = os.path.join(SCRIPT_DIR, "sync_integration_branches.ts")

def main():
    cmd = ["bun", TS_SCRIPT] + sys.argv[1:]
    res = subprocess.run(cmd)
    sys.exit(res.returncode)

if __name__ == "__main__":
    main()
