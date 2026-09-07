#!/usr/bin/env bash
# lint-flux-ignore-rfc6901.sh — Lint Flux Kustomization spec.ignore JSON pointer syntax.
#
# ─── Why this check exists ──────────────────────────────────────────────────
#
# Flux kustomize-controller uses RFC 6901 JSON pointers in `spec.ignore[].paths`.
# In RFC 6901:
#   '/' separates reference tokens
#   '~1' encodes a literal '/'
#   '~0' encodes a literal '~'
#
# Kubernetes labels and annotations frequently contain domain prefixes with slashes,
# e.g., 'signalloom.io/stunned' or 'signalloom.ai/state'.
# In a JSON pointer:
#   CORRECT:   /metadata/labels/signalloom.io~1stunned
#   INCORRECT: /metadata/labels/signalloom.io/stunned
#
# An unescaped slash creates an extra token segment, causing Flux to look for
# a nested field inside 'labels.signalloom\.io', which fails silently without
# ignoring the intended label. The stun state is then reverted on reconcile.
#
# Exit 0 = all JSON pointer paths in spec.ignore are valid RFC 6901.
# Exit 1 = one or more invalid JSON pointer paths detected.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_PATHS=("${@:-"${REPO_ROOT}/d2-osramp-fleet"}")

python3 - "${TARGET_PATHS[@]}" << 'PYEOF'
import sys
import os
import re

target_paths = sys.argv[1:]

yaml_files = []
for p in target_paths:
    if os.path.isfile(p):
        yaml_files.append(p)
    elif os.path.isdir(p):
        for root, _, files in os.walk(p):
            for f in sorted(files):
                if f.endswith(('.yaml', '.yml')):
                    yaml_files.append(os.path.join(root, f))

violations = []
checked_count = 0
files_scanned = 0

def validate_pointer(path_str, file_path, line_no):
    global checked_count
    checked_count += 1
    
    if not path_str.startswith("/"):
        violations.append(f"{file_path}:{line_no}: JSON pointer must start with '/': '{path_str}'")
        return

    # Check for invalid tilde escapes
    # ~ followed by anything other than 0 or 1, or trailing ~
    if re.search(r'~(?![01])', path_str) or path_str.endswith("~"):
        violations.append(f"{file_path}:{line_no}: Invalid RFC 6901 tilde escape in '{path_str}'")

    segments = path_str.split("/")
    # segments[0] is "" because path starts with "/"
    for i, seg in enumerate(segments):
        if seg in ("labels", "annotations"):
            remaining = segments[i+1:]
            if len(remaining) > 1:
                violations.append(
                    f"{file_path}:{line_no}: Unescaped '/' in {seg} key in '{path_str}'. "
                    f"Use '~1' instead of '/' (e.g. '/metadata/{seg}/{remaining[0]}~1{remaining[1]}')"
                )
            elif len(remaining) == 0:
                violations.append(
                    f"{file_path}:{line_no}: Incomplete path targeting whole {seg} map in '{path_str}'"
                )

for yfile in sorted(yaml_files):
    files_scanned += 1
    try:
        with open(yfile, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except Exception as e:
        continue

    in_paths = False
    paths_indent = 0

    for idx, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        
        match_paths = re.match(r'^(\s*(?:-\s*)?)paths:\s*(\[.*\])?$', line)
        if match_paths:
            indent = len(match_paths.group(1))
            inline = match_paths.group(2)
            if inline:
                items = re.findall(r'["\']([^"\']+)["\']', inline)
                for it in items:
                    validate_pointer(it, yfile, idx)
                in_paths = False
            else:
                in_paths = True
                paths_indent = indent
            continue

        if in_paths:
            # Check if this line is a dict key or sub-structure (e.g. - target:, postBuild:, etc.)
            if re.match(r'^\s*-\s*[\w.-]+:', line) or re.match(r'^\s*[\w.-]+:', line):
                in_paths = False
                continue
            item_match = re.match(r'^\s*-\s*["\']?([^"\'\s#]+)["\']?\s*$', line)
            if item_match:
                validate_pointer(item_match.group(1), yfile, idx)
            else:
                in_paths = False

if violations:
    print(f"\033[1;31m✗ Found {len(violations)} RFC 6901 JSON pointer violation(s) across {checked_count} paths in {files_scanned} files:\033[0m", file=sys.stderr)
    for v in violations:
        print(f"  \033[1;31m• {v}\033[0m", file=sys.stderr)
    sys.exit(1)
else:
    print(f"\033[1;32m✓ All {checked_count} spec.ignore JSON pointer paths across {files_scanned} files are valid RFC 6901.\033[0m")
    sys.exit(0)
PYEOF
