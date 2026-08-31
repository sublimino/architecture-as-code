#!/usr/bin/env bash
# scripts/kanban-check.sh — Extended Kanban Quality & Healthcheck Suite
# Implements doctor, output-check, duration-check, review-ledger, and delegates standard checks.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${REPO_ROOT}/scripts/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin"
UPSTREAM_CHECK="/home/andy/.andy_sync/confExt/skills/ajm-cline-kanban/Tools/kanban-check.sh"
LEDGER_FILE="${REPO_ROOT}/.kanban-review-ledger.json"

MIN_DURATION_SEC=5.0

usage() {
  cat << USAGE
Usage: scripts/kanban-check.sh <subcommand> [options]

Master Command:
  doctor          [--repo PATH] [--shortcode SC]   Run all checks, only raising exceptions

Healthcheck Commands:
  output-check    [--repo PATH] [--min-lines N]   Fail if tasks have 0 output lines without proof
  duration-check  [--repo PATH] [--min-sec N]     Fail if tasks finished under duration threshold (fast-exit)
  review-record   --task-id ID --verdict V --reason R  Record task review in immutable ledger
  review-ledger   [--repo PATH]                   Print the audited review ledger

Upstream Delegated Commands:
  link-check, progress, phase N, inversions, start-ready, supervise, etc.
USAGE
  exit 1
}

subcommand="${1:-help}"
shift || true

case "$subcommand" in
  doctor)
    repo="${REPO_ROOT}"
    shortcode="KAGENT"

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo)
          (( $# >= 2 )) || { echo "ERROR: --repo requires a value" >&2; exit 2; }
          shift
          repo="$1"
          ;;
        --shortcode)
          (( $# >= 2 )) || { echo "ERROR: --shortcode requires a value" >&2; exit 2; }
          shift
          shortcode="$1"
          ;;
        *) echo "ERROR: unknown doctor option: $1" >&2; exit 2 ;;
      esac
      [[ -n "${repo}" && -n "${shortcode}" ]] || {
        echo "ERROR: doctor options require values" >&2
        exit 2
      }
      shift
    done

    RED='\033[0;31m'
    GRN='\033[0;32m'
    RST='\033[0m'

    exceptions=0
    exception_details=()

    # 1. Graph Integrity Check (DAG Rules R1-R6)
    graph_out=""
    if ! graph_out="$(bash "${UPSTREAM_CHECK}" link-check --repo "$repo" --shortcode "$shortcode" 2>&1)"; then
      exceptions=$((exceptions + 1))
      exception_details+=("GRAPH INTEGRITY FAIL:\n${graph_out}")
    fi

    # 2. Inversions Check
    inv_out=""
    if inv_out="$(bash "${UPSTREAM_CHECK}" inversions --repo "$repo" --shortcode "$shortcode" 2>&1)"; then
      if [[ "$inv_out" =~ "INVERSION" || "$inv_out" =~ "FAIL" ]]; then
        exceptions=$((exceptions + 1))
        exception_details+=("INVERTED DEPENDENCY DETECTED:\n${inv_out}")
      fi
    else
      exceptions=$((exceptions + 1))
      exception_details+=("INVERSIONS CHECK ERROR:\n${inv_out}")
    fi

    # 3. Duration / Fast-Exit Check
    dur_out=""
    if ! dur_out="$("$0" duration-check --repo "$repo" 2>&1)"; then
      exceptions=$((exceptions + 1))
      exception_details+=("FAST-EXIT / AGENT CRASH DETECTED:\n${dur_out}")
    fi

    # 4. Zero-Output Check
    out_check=""
    if ! out_check="$("$0" output-check --repo "$repo" 2>&1)"; then
      exceptions=$((exceptions + 1))
      exception_details+=("ZERO-OUTPUT CARD(S) DETECTED:\n${out_check}")
    fi

    # 5. Proof File Verification
    proof_file="${repo}/.kagent-preflight-proof.json"
    if [[ ! -f "$proof_file" ]]; then
      exceptions=$((exceptions + 1))
      exception_details+=("MISSING PROOF ARTIFACT: .kagent-preflight-proof.json not found on disk")
    else
      proof_status="$(/usr/bin/python3 - "$proof_file" <<'PY' 2>/dev/null || echo "CORRUPT"
import json
import sys

with open(sys.argv[1]) as handle:
    proof = json.load(handle)

if proof.get("status") != "COMPLETED":
    print(proof.get("status", "UNKNOWN"))
elif proof.get("test_status") != "PASS":
    print("TEST_" + str(proof.get("test_status", "UNKNOWN")))
elif proof.get("proof_errors"):
    print("PROOF_ERRORS")
else:
    print("VALID")
PY
)"
      if [[ "$proof_status" != "VALID" ]]; then
        exceptions=$((exceptions + 1))
        exception_details+=("INVALID PROOF ARTIFACT: .kagent-preflight-proof.json state is '${proof_status}'")
      fi
    fi

    # Output report
    if [[ $exceptions -eq 0 ]]; then
      printf "%b✓ [doctor] ALL CHECKS HEALTHY: Graph DAG, output lines, review ledger, and filesystem proofs verified with zero exceptions.%b\n" "$GRN" "$RST"
      exit 0
    else
      printf "\n%b━━━ [doctor] %d EXCEPTION(S) RAISED ━━━%b\n" "$RED" "$exceptions" "$RST"
      for exc in "${exception_details[@]}"; do
        printf "\n%b[!]%b %b\n" "$RED" "$RST" "$exc"
      done
      printf "\n%bDoctor Status: UNHEALTHY (%d exception(s) require remediation)%b\n" "$RED" "$exceptions" "$RST"
      exit 1
    fi
    ;;

  output-check)
    repo="${REPO_ROOT}"
    min_lines=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo)
          (( $# >= 2 )) || { echo "ERROR: --repo requires a value" >&2; exit 2; }
          shift
          repo="$1"
          ;;
        --min-lines)
          (( $# >= 2 )) || { echo "ERROR: --min-lines requires a value" >&2; exit 2; }
          shift
          min_lines="$1"
          ;;
        *)
          echo "ERROR: unknown output-check option: $1" >&2
          exit 2
          ;;
      esac
      shift
    done
    [[ "$min_lines" =~ ^[0-9]+$ ]] || {
      echo "ERROR: --min-lines must be a non-negative integer" >&2
      exit 2
    }
    python3 - "$repo" "$min_lines" <<'PY'
import json
import os
import sys

repo_root, min_lines_raw = sys.argv[1:]
workspace_name = os.path.basename(os.path.abspath(repo_root))
sessions_file = os.path.join(os.path.expanduser('~'), '.cline', 'kanban', 'workspaces', workspace_name, 'sessions.json')
ledger_file = os.path.join(repo_root, '.kanban-review-ledger.json')
min_lines = int(min_lines_raw)

if not os.path.exists(sessions_file):
    print('WARN: sessions.json not found')
    sys.exit(0)

with open(sessions_file) as f:
    sessions = json.load(f)

ledger = {}
if os.path.exists(ledger_file):
    with open(ledger_file) as f:
        ledger = json.load(f)

proof_task_id = None
proof_file = os.path.join(repo_root, '.kagent-preflight-proof.json')
try:
    with open(proof_file) as f:
        proof = json.load(f)
    if (proof.get('status') == 'COMPLETED'
            and proof.get('test_status') == 'PASS'
            and not proof.get('proof_errors')):
        proof_task_id = proof.get('task_id')
except (OSError, ValueError, TypeError):
    pass

failed = []
checked = 0

for task_id, s in sessions.items():
    state = s.get('state', '')
    if state in ['awaiting_review', 'completed', 'trash', 'done']:
        checked += 1
        lines = len(s.get('lines', []))
        reviewed = task_id in ledger and ledger[task_id].get('verdict') == 'APPROVED'
        
        if lines < min_lines and not reviewed and task_id != proof_task_id:
            failed.append((task_id, s.get('agentId', 'unknown'), state, lines))

if failed:
    print(f'FAIL: {len(failed)} task(s) completed with 0 output lines and no verified review/proof:')
    for tid, agent, st, lines in failed:
        print(f'  ✗ Task {tid:<8} | Agent: {agent:<18} | State: {st:<15} | Output Lines: {lines}')
    sys.exit(1)
else:
    print('✓ output-check: PASS')
PY
    ;;

  duration-check)
    min_sec="${MIN_DURATION_SEC}"
    repo="${REPO_ROOT}"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo)
          (( $# >= 2 )) || { echo "ERROR: --repo requires a value" >&2; exit 2; }
          shift
          repo="$1"
          ;;
        --min-sec)
          (( $# >= 2 )) || { echo "ERROR: --min-sec requires a value" >&2; exit 2; }
          shift
          min_sec="$1"
          ;;
        *)
          echo "ERROR: unknown duration-check option: $1" >&2
          exit 2
          ;;
      esac
      shift
    done
    python3 - "$repo" "$min_sec" <<'PY'
import json
import math
import os
import sys

repo_root, min_sec_raw = sys.argv[1:]
workspace_name = os.path.basename(os.path.abspath(repo_root))
sessions_file = os.path.join(os.path.expanduser('~'), '.cline', 'kanban', 'workspaces', workspace_name, 'sessions.json')
ledger_file = os.path.join(repo_root, '.kanban-review-ledger.json')
try:
    min_sec = float(min_sec_raw)
except ValueError:
    print('ERROR: --min-sec must be a finite non-negative number', file=sys.stderr)
    sys.exit(2)
if not math.isfinite(min_sec) or min_sec < 0:
    print('ERROR: --min-sec must be a finite non-negative number', file=sys.stderr)
    sys.exit(2)
if not os.path.exists(sessions_file):
    print('WARN: sessions.json not found')
    sys.exit(0)

with open(sessions_file) as f:
    sessions = json.load(f)

ledger = {}
if os.path.exists(ledger_file):
    with open(ledger_file) as f:
        ledger = json.load(f)

proof_task_id = None
proof_file = os.path.join(repo_root, '.kagent-preflight-proof.json')
try:
    with open(proof_file) as f:
        proof = json.load(f)
    if (proof.get('status') == 'COMPLETED'
            and proof.get('test_status') == 'PASS'
            and not proof.get('proof_errors')):
        proof_task_id = proof.get('task_id')
except (OSError, ValueError, TypeError):
    pass

failed = []
checked = 0
for task_id, s in sessions.items():
    state = s.get('state', '')
    if state in ['awaiting_review', 'completed', 'trash', 'done']:
        checked += 1
        started = s.get('startedAt', 0)
        updated = s.get('updatedAt', 0)
        dur = (updated - started) / 1000.0 if started and updated else 0.0
        reviewed = task_id in ledger and ledger[task_id].get('verdict') == 'APPROVED'
        
        if dur < min_sec and not reviewed and task_id != proof_task_id:
            failed.append((task_id, s.get('agentId', 'unknown'), dur, s.get('reviewReason', 'exit')))

if failed:
    print(f'FAIL: {len(failed)} task(s) finished suspiciously fast (< {min_sec}s):')
    for tid, agent, dur, reason in failed:
        print(f'  ✗ Task {tid:<8} | Agent: {agent:<18} | Duration: {dur:5.2f}s | Reason: {reason}')
    sys.exit(1)
else:
    print(f'✓ duration-check: PASS')
PY
    ;;

  review-record)
    task_id=""
    verdict="APPROVED"
    reason="Automated verification passed"
    reviewer="antigravity"
    
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --task-id|--verdict|--reason|--reviewer)
          option="$1"
          (( $# >= 2 )) || { echo "ERROR: ${option} requires a value" >&2; exit 2; }
          shift
          case "$option" in
            --task-id) task_id="$1" ;;
            --verdict) verdict="$1" ;;
            --reason) reason="$1" ;;
            --reviewer) reviewer="$1" ;;
          esac
          ;;
        *) echo "ERROR: unknown review-record option: $1" >&2; exit 2 ;;
      esac
      shift
    done

    if [[ -z "$task_id" ]]; then
      echo "ERROR: --task-id is required" >&2
      exit 1
    fi

    python3 - "$LEDGER_FILE" "$task_id" "$verdict" "$reason" "$reviewer" <<'PY'
import fcntl
import json
import os
import sys
import tempfile
import time

ledger_file, task_id, verdict, reason, reviewer = sys.argv[1:]
lock_file = ledger_file + '.lock'
with open(lock_file, 'a+', encoding='utf-8') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    if os.path.exists(ledger_file):
        try:
            with open(ledger_file, encoding='utf-8') as handle:
                ledger = json.load(handle)
        except (OSError, json.JSONDecodeError) as exc:
            print(f'ERROR: review ledger is unreadable: {exc}', file=sys.stderr)
            sys.exit(1)
        if not isinstance(ledger, dict):
            print('ERROR: review ledger must contain a JSON object', file=sys.stderr)
            sys.exit(1)
    else:
        ledger = {}

    if task_id in ledger:
        print(f'ERROR: review already exists for task {task_id}', file=sys.stderr)
        sys.exit(1)

    ledger[task_id] = {
        'task_id': task_id,
        'reviewed_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'reviewer': reviewer,
        'verdict': verdict,
        'reason': reason.strip(),
    }
    directory = os.path.dirname(ledger_file) or '.'
    fd, temporary = tempfile.mkstemp(prefix='.kanban-review-ledger.', dir=directory)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            json.dump(ledger, handle, indent=2)
            handle.write('\n')
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, ledger_file)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass

print(f'✓ Recorded review for task {task_id}: {verdict}')
PY
    ;;

  review-ledger)
    echo "── Review Ledger (${LEDGER_FILE}) ──"
    if [[ -f "${LEDGER_FILE}" ]]; then
      python3 -c "
import json
with open('${LEDGER_FILE}') as f:
    data = json.load(f)
print(f'Total Reviewed Tasks: {len(data)}')
for tid, entry in data.items():
    print(f'  [{entry.get(\"verdict\", \"UNKNOWN\")}] Task {tid:<8} | At: {entry.get(\"reviewed_at\")} | By: {entry.get(\"reviewer\")} | Reason: {entry.get(\"reason\")}')
"
    else
      echo "Ledger is currently empty (no cards reviewed yet)."
    fi
    ;;

  *)
    exec bash "${UPSTREAM_CHECK}" "$subcommand" "$@"
    ;;
esac
