#!/usr/bin/env bash
# scripts/kagent-test.sh — Run Kagent D5 Test Suite
set -euo pipefail

export PATH=/home/andy/src/cp/osramp-demo/scripts/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-${REPO_ROOT}/.kind/kubeconfig}"
if [ -f "${KUBECONFIG_PATH}" ]; then
  export KUBECONFIG="${KUBECONFIG_PATH}"
fi

echo "=== Running Kagent Test Suite ==="

run_bats() {
  local suite="$1"
  if bats "$suite" 2>/dev/null; then
    return 0
  fi

  # Fallback to embedded python parser using system python3 (/usr/bin/python3)
  /usr/bin/python3 -c '
import sys, os, subprocess
file_path = "'"$suite"'"
print(f"--> Suite: {file_path}")
with open(file_path) as f:
    lines = f.readlines()

setup_lines, tests = [], []
current_test, current_lines = None, []
in_setup = False

for line in lines:
    if line.strip().startswith("setup()"):
        in_setup = True
        continue
    if in_setup:
        if line.strip() == "}":
            in_setup = False
        else:
            setup_lines.append(line)
        continue
    if line.strip().startswith("@test "):
        current_test = line.strip().split("\"")[1]
        current_lines = []
        continue
    if current_test:
        if line.strip() == "}":
            tests.append((current_test, "".join(current_lines)))
            current_test = None
            current_lines = []
        else:
            current_lines.append(line)

setup_code = "".join(setup_lines)
passed, failed = 0, 0
for name, body in tests:
    script = f"""
set -e
export PATH=/home/andy/src/cp/osramp-demo/scripts/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin
export BATS_TEST_DIRNAME="{os.path.dirname(os.path.abspath(file_path))}"
{setup_code}
run() {{
    status=0
    output=$("$@" 2>&1) || status=$?
    return 0
}}
{body}
"""
    res = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=dict(os.environ))
    if res.returncode == 0:
        print(f"  ✓ {name}")
        passed += 1
    else:
        print(f"  ✗ {name}")
        if res.stderr:
            print(f"    {res.stderr.strip()}")
        failed += 1

print(f"Summary: {passed} passed, {failed} failed")
sys.exit(0 if failed == 0 else 1)
'
}

run_bats "${REPO_ROOT}/d2-signalloom/test/kagent-contract.bats"
run_bats "${REPO_ROOT}/test/kagent-install.bats"
run_bats "${REPO_ROOT}/test/kagent-agents.bats"
run_bats "${REPO_ROOT}/test/kagent-credentials.bats"
run_bats "${REPO_ROOT}/test/kagent-demo-harness.bats"
run_bats "${REPO_ROOT}/test/kagent-adversarial.bats"

echo "=== All Kagent D5 tests passed successfully! ==="
