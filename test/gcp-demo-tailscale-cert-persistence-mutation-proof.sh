#!/usr/bin/env bash
#
# Proves that test/terraform-tailscale-cert-persistence.bats can actually FAIL.
#
# ─── Why this file exists ───────────────────────────────────────────────────
#
# That suite is mostly greps and absence-of-bad assertions. Both shapes pass
# trivially when the thing they read has moved, been renamed, or is empty — so a
# green run is not on its own evidence of anything. This harness mutates the
# REAL files, one property at a time, and requires the specific test guarding
# that property to go red. A mutation that leaves the suite green names a guard
# that was never testing what its name claims.
#
# ─── Safety ─────────────────────────────────────────────────────────────────
#
# Files are backed up by COPY and restored from that copy. Deliberately NOT
# `git checkout` / `git stash`: this repo is worked in worktrees with
# uncommitted changes in flight, and a proof harness that reverts tracked files
# destroys the very work it was invoked to check — which reads exactly like a
# real finding and has cost this repo a session before.
#
# The restore runs from a trap on EXIT, INT, TERM and HUP. It cannot cover
# SIGKILL; if this script is `kill -9`d the repo is left mutated, and
# `git diff` is the recovery.
#
# No `set -e`. An errexit shell combined with an EXIT trap lets a failing last
# command in the trap replace the script's real verdict, which has previously
# turned an 8/8 pass into a reported failure here.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly SUITE="${REPO_ROOT}/test/terraform-tailscale-cert-persistence.bats"

readonly STARTUP="${REPO_ROOT}/terraform/modules/compute/startup/demo-vm.sh"
readonly BOOTSTRAP_MAIN="${REPO_ROOT}/terraform/bootstrap/main.tf"
readonly ENV_MAIN="${REPO_ROOT}/terraform/environments/main.tf"
readonly COMPUTE_MAIN="${REPO_ROOT}/terraform/modules/compute/main.tf"

readonly FILES=("${STARTUP}" "${BOOTSTRAP_MAIN}" "${ENV_MAIN}" "${COMPUTE_MAIN}")

BACKUP="$(mktemp -d)"
readonly BACKUP

PASS=0
FAIL=0

# Backup key derived from the FULL path, not the basename.
#
# This harness previously keyed on `basename`, and three of the four files it
# manages are called main.tf — terraform/platform, terraform/environments and
# terraform/modules/compute. They collided in the backup directory, the last
# copy won, and `restore_all` then wrote the compute module's content over the
# platform and environments roots. The tree was left silently corrupted with
# three identical main.tf files, and the mutation results that followed were
# nonsense: nine mutations reported "changed nothing" because they were being
# applied to the wrong file's content.
#
# Slashes are replaced rather than the path being nested, so the backup
# directory stays flat and the mapping is total and obviously injective.
backup_key() {
  printf '%s' "${1#"${REPO_ROOT}/"}" | tr '/' '_'
}

restore_all() {
  local f key
  for f in "${FILES[@]}"; do
    key="$(backup_key "$f")"
    if [[ -f "${BACKUP}/${key}" ]]; then
      cp -p "${BACKUP}/${key}" "$f"
    fi
  done
}

cleanup() {
  restore_all
  rm -rf "${BACKUP}"
  # NOTHING after this that can fail — see the errexit note in the header.
}
trap cleanup EXIT INT TERM HUP

for f in "${FILES[@]}"; do
  cp -p "$f" "${BACKUP}/$(backup_key "$f")" || {
    echo "FATAL: could not back up $f" >&2
    exit 1
  }
done

# The backup must hold one entry per managed file. A collision here is the
# corruption described above, and it is cheap to refuse rather than discover.
if [[ "$(find "${BACKUP}" -maxdepth 1 -type f | wc -l)" -ne "${#FILES[@]}" ]]; then
  echo "FATAL: backup key collision — ${#FILES[@]} files produced fewer backups." >&2
  echo "Restoring would write one file's content over another." >&2
  exit 1
fi

# Runs ONE test by name and reports whether it failed.
#
# `bats -f` takes a regex over test names. The name is matched loosely so a
# later rewording of the test does not silently stop matching and report a
# vacuous pass — MUTATION_TEST_MISSING below catches the case where it matches
# nothing at all.
suite_test_fails() {
  local pattern="$1" out rc
  out="$(cd "${REPO_ROOT}" && bats -f "${pattern}" "${SUITE}" 2>&1)"
  rc=$?

  # A pattern that matched NO test exits 0 with no test lines, which would read
  # as "the guard did not fire" when the truth is "there is no such guard".
  # pipefail-safe: $out is already fully captured in memory; printf's single write cannot race grep -q, and this is an if-condition, exempt from errexit anyway.
  if ! printf '%s' "$out" | grep -qE '^(ok|not ok) '; then
    echo "    HARNESS FAULT: no test matched /${pattern}/" >&2
    return 2
  fi

  [[ $rc -ne 0 ]]
}

# mutate <label> <test-name-regex> <file> <sed-expression>
#
# Applies the mutation, asserts the named guard goes red, restores.
mutate() {
  local label="$1" pattern="$2" file="$3" expr="$4"
  local before after

  before="$(md5sum "$file" | cut -d' ' -f1)"
  sed -i -e "$expr" "$file"
  after="$(md5sum "$file" | cut -d' ' -f1)"

  # A sed that matched nothing is a NO-OP that prints success — the exact way a
  # mutation harness certifies a guard it never actually challenged.
  if [[ "$before" == "$after" ]]; then
    echo "  [BROKEN] ${label}"
    echo "    the mutation changed nothing; the pattern no longer matches the file"
    FAIL=$((FAIL + 1))
    restore_all
    return 0
  fi

  if suite_test_fails "$pattern"; then
    echo "  [RED   ] ${label}"
    PASS=$((PASS + 1))
  else
    echo "  [GREEN ] ${label}"
    echo "    the suite stayed green under this mutation — the guard is not testing"
    echo "    the property its name claims"
    FAIL=$((FAIL + 1))
  fi

  restore_all
}

echo "=== baseline: the suite must be GREEN before any mutation ==="
if (cd "${REPO_ROOT}" && bats "${SUITE}" >/dev/null 2>&1); then
  echo "  [OK    ] baseline green"
else
  echo "  [FATAL ] the suite is already failing; mutation results would be meaningless" >&2
  exit 1
fi

echo
echo "=== mutations ==="

# 1. The store moves out of the destroy-surviving root. This is the defect the
#    whole change exists to prevent: the bucket still exists, still holds certs,
#    and is deleted by the destroy that burns the ACME allowance.
mutate "bucket renamed out of the bootstrap root" \
  "declared in the bootstrap root" \
  "${BOOTSTRAP_MAIN}" \
  's/resource "google_storage_bucket" "tailnet_certs"/resource "google_storage_bucket" "tailnet_certs_moved"/'

# 2. prevent_destroy removed — a `terraform destroy` against platform would then
#    take the bucket with it.
mutate "prevent_destroy dropped from the bucket" \
  "carries prevent_destroy" \
  "${BOOTSTRAP_MAIN}" \
  's/prevent_destroy = true/prevent_destroy = false/'

# 3. force_destroy flipped — a non-empty bucket becomes silently deletable.
mutate "force_destroy flipped to true" \
  "carries prevent_destroy" \
  "${BOOTSTRAP_MAIN}" \
  's/force_destroy = false/force_destroy = true/'

# 4. ACLs back on — IAM stops being the only answer to "who can read this key".
mutate "uniform bucket level access disabled" \
  "blocks public access" \
  "${BOOTSTRAP_MAIN}" \
  's/uniform_bucket_level_access = true/uniform_bucket_level_access = false/'

# 5. Public access prevention relaxed.
mutate "public access prevention relaxed" \
  "blocks public access" \
  "${BOOTSTRAP_MAIN}" \
  's/public_access_prevention    = "enforced"/public_access_prevention    = "inherited"/'

# 6. THE security boundary: the per-lane IAM condition removed, so every lane's
#    runtime account can read every other lane's TLS private key.
mutate "per-lane IAM condition deleted" \
  "conditioned on its own object prefix" \
  "${BOOTSTRAP_MAIN}" \
  '/condition {/,/^  }$/d'

# 7. The condition anchor widened from the lane prefix to the whole bucket —
#    the subtle version of 6, which still LOOKS like a conditioned grant.
mutate "IAM condition anchor widened to the whole bucket" \
  "conditioned on its own object prefix" \
  "${BOOTSTRAP_MAIN}" \
  's|/objects/\${each.key}/|/objects/|'

# 8. Role escalated to one that can rewrite the IAM confining it.
mutate "grant escalated to roles/storage.admin" \
  "objectAdmin, not a role that can rewrite" \
  "${BOOTSTRAP_MAIN}" \
  's|roles/storage.objectAdmin|roles/storage.admin|'

# 9. THE ordering mutation. Moves the restore call after the package install, so
#    tailscaled starts — and requests a certificate — before the restore runs.
#    Nothing else in the repo notices; the estate simply goes back to spending
#    one issuance per rebuild.
mutate "restore moved after install_tailscale_package" \
  "called BEFORE install_tailscale_package" \
  "${STARTUP}" \
  's/^  restore_tailscale_certs "\$cert_bucket" "\$cert_prefix"$/  RESTORE_MOVED_MARKER=1/'

# 10. The restore call removed entirely.
mutate "restore call removed from install_tailscale" \
  "called BEFORE install_tailscale_package" \
  "${STARTUP}" \
  '/^  restore_tailscale_certs "\$cert_bucket" "\$cert_prefix"$/d'

# 11. Failure marker silenced — a failed restore then looks exactly like a
#     first-ever boot, which is the silent-failure mode the marker exists for.
mutate "failure marker write removed" \
  "failed listing writes the marker" \
  "${STARTUP}" \
  's|printf .%s\\n. "\$reason" >"\$TS_CERT_MARKER" 2>/dev/null .. true|true|'

# 12. Partial-download cleanup removed — a truncated .key survives and
#     tailscaled fails to parse it rather than requesting a certificate.
mutate "partial-file cleanup removed" \
  "partial download is removed" \
  "${STARTUP}" \
  's|^      rm -f "\${TS_CERT_DIR}/\${base}" 2>/dev/null .. true$|      : |'

# 13. Incomplete-pair check removed — a cert with no key reports success.
mutate "incomplete certificate pair accepted" \
  "certificate without its key" \
  "${STARTUP}" \
  's|if \[\[ -z "\$have_crt" .. -z "\$have_key" \]\]; then|if false; then|'

# 14. Restored key made world-readable.
mutate "restored key left world-readable" \
  "not world-readable" \
  "${STARTUP}" \
  's|chmod 0600 "\${TS_CERT_DIR}/\${base}"|chmod 0644 "${TS_CERT_DIR}/${base}"|'

# 15. The save timer enabled but never started — armed for the NEXT boot only,
#     so a renewal is never captured and the bucket silently goes stale.
mutate "save timer enabled but never started" \
  "enabled AND started" \
  "${STARTUP}" \
  's|^  systemctl start "\$TS_CERT_SAVE_TIMER_NAME" .. {$|  false \&\& {|'

# 16. Bucket coordinates stop reaching the VM.
mutate "cert bucket metadata key removed" \
  "no credential is published to instance metadata" \
  "${COMPUTE_MAIN}" \
  's/signalloom-tailscale-cert-bucket = var.tailscale_cert_bucket_name/signalloom-tailscale-gone = var.tailscale_cert_bucket_name/'

# 17. The environments root stops reading the platform output, so the bucket
#     exists and the VM is never told about it.
mutate "environments root stops reading the bucket variable" \
  "consumed by the environments root" \
  "${ENV_MAIN}" \
  's/var\.tailnet_cert_bucket_name/var.tailnet_cert_bucket_name_gone/g'

# 18. The lane prefix stops being each.key, so the bootstrap root's IAM
#     condition denies every read and write from the VM.
mutate "lane prefix decoupled from the environment key" \
  "prefix passed to the VM is the environment key" \
  "${ENV_MAIN}" \
  's/tailscale_cert_prefix      = local\.tailnet_cert_bucket_name == "" ? "" : each\.key/tailscale_cert_prefix      = "shared"/'


# ── The save path must never destroy the persisted copy ────────────────────
#
# The two standing decisions meet here: persist the certificate, and keep the
# deregistration flow untouched. A save helper that reconciled the bucket to
# the local directory would let a logout empty the store an hour later.

# 19. The helper deletes bucket objects that have no local counterpart, so a
#     logout that clears /var/lib/tailscale/certs takes the durable copy with
#     it on the next tick.
mutate "save helper made to mirror rather than upload" \
  "emptied cert directory does not delete" \
  "${STARTUP}" \
  's|^uploaded=0$|curl -X DELETE "\\$GCS_API/storage/v1/b/\\$BUCKET/o/\\$PREFIX" \|\| true\nuploaded=0|'

# 20. The same delete, placed INSIDE the upload loop — a branch the empty
#     directory run of mutation 30 never reaches. This is what the static
#     guard is for: a delete on a path no test happens to walk is still a
#     delete, and the bucket is the only copy that survives a destroy.
mutate "delete verb hidden on a branch no run reaches" \
  "upload-only" \
  "${STARTUP}" \
  's|    log "saved \\\$base to gs:|    curl --request DELETE https://example.invalid/x \|\| true\n    log "saved \\\$base to gs:|'

# 21. The heredoc that writes the save helper fails to expand, which leaves a
#     ZERO-BYTE helper behind. Found by mutation 31's first draft, which used
#     an unbound variable: the redirection creates the file before expansion,
#     `bash -n` passes an empty file, and the `if ! cat` guard never fires
#     because the shell dies at the expansion rather than inside cat. The
#     install then reads as healthy while the timer runs a script that saves
#     nothing — and the next rebuild spends an issuance.
mutate "save helper heredoc truncated to nothing" \
  "generated save helper is valid bash" \
  "${STARTUP}" \
  's|^BUCKET="${bucket}"$|BUCKET="${bucket}${signalloom_undefined_on_purpose}"|'

echo
echo "=== result ==="
echo "  mutations that turned the suite red : ${PASS}"
echo "  mutations the suite did not catch   : ${FAIL}"

if [[ "${FAIL}" -ne 0 ]]; then
  echo
  echo "FAIL: ${FAIL} mutation(s) left the suite green. Those guards do not test" >&2
  echo "the property their names claim." >&2
  exit 1
fi

echo
echo "PASS: every mutation was caught."
