#!/usr/bin/env bash
#
# Proves d2-signalloom/test/spire-server-durability.bats actually fails when the
# durability defect is present.
#
# Every assertion in that suite was RED against the tree before the PVC landed,
# which is real evidence — but it is evidence taken once, by hand, at a moment
# nobody can re-run. The suite's value from here on is as a guard against the
# defect being reintroduced, and a guard that has never been shown to go red is
# indistinguishable from one that cannot. This repository has shipped both
# shapes already: a scanner that silently scanned nothing, and a bats helper
# that returned build output so its dependants passed vacuously through a
# mutation designed to break them.
#
# So each assertion gets its specific defect injected and is required to exit
# NON-ZERO, then the file is restored byte-for-byte and it is required to pass
# again.
#
# ── The three things this harness does that are not optional ───────────────
#
# 1. PREFLIGHT. Each test is run BEFORE its mutation and must already be green.
#    Without this, "bats could not run at all" reports identically to "the guard
#    fired" — a false proof, which is the exact failure
#    audit-guard-reintroduction-proof.sh emitted before it was fixed.
#
# 2. THE MUTATION ASSERTS ITSELF. Every substitution counts its matches and
#    aborts on zero. A find/replace whose pattern has drifted silently changes
#    nothing, the test then passes for the honest reason that the code is still
#    correct, and the harness reports "guard did not fire" — accusing a working
#    guard because the harness broke.
#
# 3. RESTORATION IS BY `cp` FROM A BACKUP, KEYED ON FULL RELATIVE PATH, AND IS
#    VERIFIED BY sha256. Never `git checkout --`: that would discard
#    uncommitted work in the same file. Never key a backup on basename — three
#    files here are named for their component and a basename-keyed backup dir
#    silently collides.
#
# Usage:  bash d2-signalloom/test/spire-durability-mutation-proof.sh
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUITE="${REPO_ROOT}/d2-signalloom/test/spire-server-durability.bats"
RBAC_SUITE="${REPO_ROOT}/d2-signalloom/test/spire-openbao-sync-rbac-placement.bats"

# The suite the next check() runs against. Set per group rather than threaded
# through every call, so adding a group cannot silently point at the wrong file.
CURRENT_SUITE="$SUITE"

MANIFEST="${REPO_ROOT}/d2-signalloom/infra/inf-bao/controllers/base/openbao-spire.yaml"
CONFIG="${REPO_ROOT}/d2-signalloom/infra/inf-bao/controllers/base/spire-openbao-config.yaml"
AGENT="${REPO_ROOT}/d2-signalloom/infra/inf-bao/configs/base/spire-agent.yaml"
SYNC="${REPO_ROOT}/d2-signalloom/infra/inf-bao/controllers/base/spire-openbao-sync-cronjob.yaml"
FLEET="${REPO_ROOT}/d2-osramp-fleet/tenants/local/signalloom.yaml"

ALL_FILES=("$MANIFEST" "$CONFIG" "$AGENT" "$SYNC" "$FLEET")

BACKUP_DIR="$(mktemp -d)"
CHECKS=0
FAILURES=0

green() { printf '\033[1;32m  PASS\033[0m %s\n' "$*"; }
red() { printf '\033[1;31m  FAIL\033[0m %s\n' "$*"; }
note() { printf '\033[1;36m[proof]\033[0m %s\n' "$*"; }

# Backups keyed on the path RELATIVE TO THE REPO, so two files that share a
# basename cannot overwrite each other's backup.
backup() {
	local f rel
	for f in "$@"; do
		rel="${f#"${REPO_ROOT}"/}"
		mkdir -p "${BACKUP_DIR}/$(dirname "$rel")"
		cp -p "$f" "${BACKUP_DIR}/${rel}"
	done
}

restore() {
	local f rel
	for f in "$@"; do
		rel="${f#"${REPO_ROOT}"/}"
		[ -f "${BACKUP_DIR}/${rel}" ] || continue
		cp -p "${BACKUP_DIR}/${rel}" "$f"
	done
}

# Restore unconditionally, including on SIGTERM and SIGINT. An EXIT trap alone
# leaves the tree mutated if the harness is killed, and a mutated manifest that
# looks like ordinary uncommitted work is a genuinely dangerous thing to leave
# behind in a repo several agents are writing to.
cleanup() {
	restore "${ALL_FILES[@]}"
	rm -rf "$BACKUP_DIR"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# Exact-substring substitution that refuses to be a no-op.
mutate() { # file old new
	python3 - "$@" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
n = s.count(old)
if n == 0:
    sys.stderr.write("mutation pattern not found -- the harness is broken, not the guard:\n%r\n" % old)
    sys.exit(2)
open(path, "w").write(s.replace(old, new))
PY
}

# Run exactly one test out of the suite. bats -f takes a regex over the test
# name; the names here are prose, so it is anchored on a distinctive fragment.
run_one() { # name-fragment
	bats -f "$1" "$CURRENT_SUITE" >/dev/null 2>&1
}

# How many tests a fragment actually selects.
#
# `bats -f <fragment-that-matches-nothing>` prints "1..0" and EXITS 0 (verified,
# not assumed). A fragment that has drifted out of date therefore reports green
# both before and after the mutation, which this harness would render as
# "guard stayed GREEN with the defect present" -- an accusation against a guard
# that is in fact fine, for a reason the message does not mention. The direction
# of that error is at least safe (a stale fragment can never manufacture a
# false PASS), but a proof harness whose failure message names the wrong culprit
# gets ignored, so the arity is checked explicitly and named for what it is.
fragment_arity() { # name-fragment
	bats -c -f "$1" "$CURRENT_SUITE" 2>/dev/null
}

# name, files-to-back-up, the mutation (a function body), the test that must fail
check() { # description test-fragment mutation-command...
	local desc="$1" fragment="$2"
	shift 2
	CHECKS=$((CHECKS + 1))
	note "$desc"

	# 0. The fragment must select exactly one test. Zero means the harness is
	#    stale, not that the guard is broken.
	local n
	n="$(fragment_arity "$fragment")"
	if [ "$n" != "1" ]; then
		red "$desc -- fragment '$fragment' selects ${n} tests, expected 1; harness is stale"
		FAILURES=$((FAILURES + 1))
		return 0
	fi

	# 1. Preflight: green BEFORE the mutation, or nothing below proves anything.
	if ! run_one "$fragment"; then
		red "$desc -- test was NOT green before the mutation; nothing was proved"
		FAILURES=$((FAILURES + 1))
		return 0
	fi

	# 2. Inject. `mutate` exits non-zero if its pattern matched nothing.
	if ! "$@"; then
		red "$desc -- could not inject the defect; harness is stale"
		FAILURES=$((FAILURES + 1))
		restore "${ALL_FILES[@]}"
		return 0
	fi

	# 3. The assertion that matters: the guard must go RED.
	if run_one "$fragment"; then
		red "$desc -- guard stayed GREEN with the defect present"
		FAILURES=$((FAILURES + 1))
	else
		green "$desc -- guard went red"
	fi

	# 4. Restore and require green again, so a "red" that was really a broken
	#    tree cannot be counted as a successful falsification.
	restore "${ALL_FILES[@]}"
	if ! run_one "$fragment"; then
		red "$desc -- test did not recover after restore"
		FAILURES=$((FAILURES + 1))
	fi
}

command -v bats >/dev/null || { echo "bats is not installed" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl is required to render the kustomization" >&2; exit 1; }
command -v yq >/dev/null || { echo "yq is required" >&2; exit 1; }

backup "${ALL_FILES[@]}"

note "9 mutations (group 1) against $(basename "$SUITE") -- one per test, and the suite has $(bats -c "$SUITE") tests"

# The mechanism-presence check gets a mutation too. It is the assertion the
# other six depend on: if data_dir cannot be extracted, every derived comparison
# below it compares "" against "" and the suite passes over a Deployment with no
# volumes at all. Anchored on the trust_domain that precedes it, because the
# same file declares an agent data_dir on the next line and a bare replacement
# would silently mutate both.
check "server.conf data_dir removed (every derived assertion depends on it)" \
	"still declares a data_dir" \
	mutate "$CONFIG" \
'trust_domain = "signalloom.demo" data_dir = "/run/spire/data" }
    plugins { DataStore' \
'trust_domain = "signalloom.demo" }
    plugins { DataStore'

check "data volume and its mount removed entirely (the original defect)" \
	"mounted from a PersistentVolumeClaim" \
	mutate "$MANIFEST" \
'            - name: data
              mountPath: /run/spire/data' \
''

check "data volume swapped for an emptyDir" \
	"not backed by ephemeral storage" \
	mutate "$MANIFEST" \
'          persistentVolumeClaim:
            claimName: spire-server-data' \
'          emptyDir: {}'

check "PersistentVolumeClaim resource deleted, mount left dangling" \
	"declared in this slice, RWO" \
	mutate "$MANIFEST" \
'kind: PersistentVolumeClaim' \
'kind: ConfigMapButNotAClaim'

check "claim widened to ReadWriteMany" \
	"declared in this slice, RWO" \
	mutate "$MANIFEST" \
'accessModes: ["ReadWriteOnce"]' \
'accessModes: ["ReadWriteMany"]'

check "strategy reverted to RollingUpdate (the RWO deadlock)" \
	"Recreate strategy" \
	mutate "$MANIFEST" \
'  strategy:
    type: Recreate' \
'  strategy:
    type: RollingUpdate'

check "strategy stanza deleted, defaulting to RollingUpdate" \
	"Recreate strategy" \
	mutate "$MANIFEST" \
'  strategy:
    type: Recreate
' \
''

check "CA keys_path moved outside the persisted mount" \
	"sit under the persisted mount" \
	mutate "$CONFIG" \
'keys_path = "/run/spire/data/keys.json"' \
'keys_path = "/tmp/keys.json"'

check "spire-agent data_dir made ephemeral instead" \
	"spire-agent keeps its persistent data_dir" \
	mutate "$AGENT" \
'          hostPath:
            path: /var/lib/spire-agent/data
            type: DirectoryOrCreate' \
'          emptyDir: {}'

# ── Group 2: the RBAC placement guard ──────────────────────────────────────
#
# This guard exists because the deadlock it catches has landed twice, and the
# second time a long, correct comment on the FIRST occurrence did not prevent
# it — a comment is only read by someone already looking at that object. So the
# guard has to be able to fail, and that is what these mutations establish.
CURRENT_SUITE="$RBAC_SUITE"
note "4 further mutations against $(basename "$RBAC_SUITE")"

check "the RBAC is moved back into the flux-reconciled slice (the actual regression)" \
	"binds a Role it also declares" \
	mutate "$SYNC" \
'---
apiVersion: v1
kind: ConfigMap
metadata:
  name: spire-openbao-sync-script' \
'---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: spire-openbao-sync
  namespace: inf-bao
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: spire-openbao-sync
  namespace: inf-bao
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: spire-openbao-sync
subjects:
  - kind: ServiceAccount
    name: spire-openbao-sync
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: spire-openbao-sync-script'

check "the RoleBinding is dropped from the ResourceSet (CronJob left with no authority)" \
	"lives in the signalloom-spire-rbac ResourceSet" \
	mutate "$FLEET" \
'      kind: RoleBinding
      metadata:
        name: spire-openbao-sync
        namespace: inf-bao' \
'      kind: RoleBinding
      metadata:
        name: spire-openbao-sync-RENAMED
        namespace: inf-bao'

check "the binding subject drifts off the CronJob ServiceAccount" \
	"binds the ServiceAccount that the CronJob runs as" \
	mutate "$FLEET" \
'      subjects:
        - kind: ServiceAccount
          name: spire-openbao-sync
          namespace: inf-bao' \
'      subjects:
        - kind: ServiceAccount
          name: spire-openbao-sync-typo
          namespace: inf-bao'

check "the CronJob drifts out of the controllers slice" \
	"stay in the controllers slice" \
	mutate "$SYNC" \
'  name: spire-openbao-sync-script' \
'  name: spire-openbao-sync-script-renamed'

CURRENT_SUITE="$SUITE"

# ── Byte-for-byte restoration, asserted rather than assumed ────────────────
note "verifying restoration"
RESTORE_BAD=0
for f in "${ALL_FILES[@]}"; do
	rel="${f#"${REPO_ROOT}"/}"
	a="$(sha256sum "${BACKUP_DIR}/${rel}" | cut -d' ' -f1)"
	b="$(sha256sum "$f" | cut -d' ' -f1)"
	if [ "$a" = "$b" ]; then
		green "restored byte-identically: $rel"
	else
		red "NOT restored: $rel ($a != $b)"
		RESTORE_BAD=1
		FAILURES=$((FAILURES + 1))
	fi
done
[ "$RESTORE_BAD" -eq 0 ] || note "the tree is NOT clean -- restore ${MANIFEST} by hand"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
	note "all ${CHECKS} mutations falsified the guard; tree restored"
	exit 0
fi
note "${FAILURES} problem(s) across ${CHECKS} mutations"
exit 1
