#!/usr/bin/env bats
#
# The cosign keypair must survive the delivery that rebuilds the checkout.
#
# ─── The defect this suite exists to prevent ────────────────────────────────
#
# `.keys/` is gitignored, so `git archive HEAD` cannot carry it. The VM
# therefore has no keypair until `make signing-keys` mints one, and signing-keys
# writes into $(KEYS_DIR) — which, unconfigured, resolves to the delivered
# tree's own `.keys/`. deliver_code opens with `sudo rm -rf $REMOTE_WORK_DIR`.
#
#   run 1  mint key A -> push signed by A -> bootstrap-local installs A into
#          flux-system/cosign-pub. Consistent, and it works.
#   run 2  rm -rf the tree, and key A with it -> mint key B -> push-local.sh's
#          trust preflight finds the cluster still trusting A, and refuses.
#
# Captured on sl-demo-1-vm 2026-08-20: cluster afddf5a2626d87bf against a
# delivered tree holding 2575de005cbcba9e. A FIRST run always worked and every
# re-run could not, which is the property that made this expensive to diagnose —
# a retry fails differently from the original, so the retry looks like new
# information when it is the same defect one state further along.
#
# ─── Why the guard and not just the default ─────────────────────────────────
#
# The fix is one path: keys live in a sibling of the checkout instead of inside
# it. A correct default is not enough on its own, because the path is an
# override and the failure mode of getting it wrong is SILENT — a nested keys
# directory is deleted on the next delivery and everything downstream reports
# the same "no matching signatures" it reported before. So the durability
# property is asserted here rather than trusted to stay true.
#
# test/gcp-demo-keys-persistence-mutation-proof.sh proves every assertion below
# can actually fail. Several of these are absence-of-bad assertions, which are
# trivially satisfied by nothing-being-present, and this file is not evidence of
# anything without that harness.
#
# Offline: reads files and runs the driver's own guard with stubs. No network,
# no cloud, no VM.

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  export UP="${REPO_ROOT}/scripts/gcp-tf/demo-up.sh"
  export PIPE="${REPO_ROOT}/scripts/gcp-tf/demo-pipeline.sh"
}

setup() {
  [ -f "${UP}" ]
  [ -f "${PIPE}" ]
}

# Run assert_keys_dir_is_durable() in isolation, with the two variables it reads
# supplied and `die` stubbed to something observable.
#
# The function is extracted from the real file rather than reimplemented here.
# A reimplementation would be a second copy of the logic that agrees with itself
# no matter what the shipped code does — the contract-halves failure this repo
# has already paid for once.
run_durability_guard() {
  local keys="$1" work="$2"
  local harness="${BATS_TEST_TMPDIR}/guard.sh"

  {
    echo 'die() { printf "DIED: %s\n" "$*"; exit 9; }'
    printf 'REMOTE_KEYS_DIR=%q\n' "$keys"
    printf 'REMOTE_WORK_DIR=%q\n' "$work"
    sed -n '/^assert_keys_dir_is_durable() {/,/^}/p' "${UP}"
    echo 'assert_keys_dir_is_durable'
    echo 'echo ACCEPTED'
  } >"${harness}"

  bash "${harness}"
}

@test "KEYS the durability guard is defined in the driver (no vacuous suite)" {
  # Every test below extracts this function. If it is renamed or deleted the
  # extraction yields an empty harness, `assert_keys_dir_is_durable` becomes a
  # command-not-found, and a suite that asserts on exit codes could read that as
  # the guard firing. Checked once, explicitly, so the rest can rely on it.
  run sed -n '/^assert_keys_dir_is_durable() {/,/^}/p' "${UP}"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  printf '%s\n' "$output" | grep -q 'REMOTE_KEYS_DIR'
  printf '%s\n' "$output" | grep -q 'REMOTE_WORK_DIR'
}

@test "KEYS a sibling of the checkout is accepted" {
  # The positive control. Without it every assertion below is satisfied by a
  # guard that refuses everything, which would be just as broken and would read
  # as a perfect pass.
  run run_durability_guard /opt/signalloom/keys /opt/signalloom/repo
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'ACCEPTED'
}

@test "KEYS a keys dir INSIDE the checkout is refused" {
  # The actual defect: this is where signing-keys writes by default, and it is
  # deleted by the rm -rf at the top of deliver_code.
  run run_durability_guard /opt/signalloom/repo/.keys /opt/signalloom/repo
  [ "$status" -eq 9 ]
  printf '%s\n' "$output" | grep -q 'DIED'
  # The message must name the mechanism, not merely refuse. A refusal that does
  # not say `rm -rf` sends the reader looking at cosign.
  printf '%s\n' "$output" | grep -q 'rm -rf'
}

@test "KEYS the checkout itself is refused" {
  run run_durability_guard /opt/signalloom/repo /opt/signalloom/repo
  [ "$status" -eq 9 ]
}

@test "KEYS a deeply nested keys dir is refused" {
  run run_durability_guard /opt/signalloom/repo/a/b/c /opt/signalloom/repo
  [ "$status" -eq 9 ]
}

@test "KEYS a sibling whose name merely starts with the work dir is ACCEPTED" {
  # /opt/signalloom/repo-keys is NOT inside /opt/signalloom/repo, and a bare
  # prefix test cannot tell the two apart. This is the assertion that forces the
  # trailing-slash form; without it the obvious implementation is wrong in a
  # direction that only ever refuses valid input, which is the quieter of the
  # two failures and would be found by an operator rather than by this file.
  run run_durability_guard /opt/signalloom/repo-keys /opt/signalloom/repo
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'ACCEPTED'
}

@test "KEYS a relative keys dir is refused" {
  # A relative path resolves against the pipeline's cwd, which IS the delivered
  # tree — the one place it must not be. Refused explicitly rather than left to
  # the nesting check, which compares strings and would accept '.keys' as a
  # non-prefix of /opt/signalloom/repo and be wrong.
  run run_durability_guard .keys /opt/signalloom/repo
  [ "$status" -eq 9 ]
  printf '%s\n' "$output" | grep -qi 'absolute'
}

@test "KEYS an empty keys dir is refused, and says so specifically" {
  # The message matters here, and asserting it is what makes the empty-value
  # check testable at all.
  #
  # Deleting that check does NOT make an empty value acceptable: '' fails the
  # absolute-path `case` immediately afterwards and is still refused. So a test
  # that asserted only the exit status would stay green with the check removed —
  # a rule that is logically unreachable as a distinct failure, found by deleting
  # it and watching nothing go red.
  #
  # The check earns its place by producing the RIGHT diagnosis: "empty" sends the
  # reader to the variable, "must be absolute" sends them to a path that is not
  # there to be looked at. That distinction is the thing worth keeping, so that
  # is the thing asserted.
  run run_durability_guard "" /opt/signalloom/repo
  [ "$status" -eq 9 ]
  printf '%s\n' "$output" | grep -qi 'is empty' || {
    echo "an empty keys dir was refused, but not AS an empty one:" >&2
    printf '%s\n' "$output" >&2
    return 1
  }
}

@test "KEYS a trailing slash does not defeat the nesting check" {
  # '/opt/signalloom/repo/.keys/' must be refused exactly as the unslashed form
  # is. Path strings arriving from an environment variable are not normalised,
  # and a guard that can be bypassed by one character is decoration.
  run run_durability_guard /opt/signalloom/repo/.keys/ /opt/signalloom/repo/
  [ "$status" -eq 9 ]
}

@test "KEYS the shipped default is durable against the shipped work dir" {
  # Both defaults are read out of the file, so this asserts the pair that
  # actually ships rather than a pair restated here. A change to either default
  # that reintroduces nesting fails this without anyone remembering to update a
  # constant.
  local keys work
  keys="$(grep -oE '^REMOTE_KEYS_DIR="\$\{GCP_TF_DEMO_REMOTE_KEYS_DIR:-[^}]+\}"' "${UP}" \
    | sed -E 's/.*:-//; s/\}"$//')"
  work="$(grep -oE '^REMOTE_WORK_DIR="\$\{GCP_TF_DEMO_REMOTE_DIR:-[^}]+\}"' "${UP}" \
    | sed -E 's/.*:-//; s/\}"$//')"

  [ -n "$keys" ] || { echo "could not extract the REMOTE_KEYS_DIR default" >&2; return 1; }
  [ -n "$work" ] || { echo "could not extract the REMOTE_WORK_DIR default" >&2; return 1; }

  run run_durability_guard "$keys" "$work"
  [ "$status" -eq 0 ] || {
    echo "the SHIPPED defaults are not durable: keys=${keys} work=${work}" >&2
    echo "$output" >&2
    return 1
  }
}

@test "KEYS the guard runs during delivery, before the pipeline is invoked" {
  # Being correct is not enough if nothing calls it. Scoped to code, because the
  # rationale comment above the function names it in prose and a whole-file grep
  # would be satisfied by the documentation explaining the rule.
  local body
  body="$(sed -n '/^provision_remote_paths() {/,/^}/p' "${UP}" | grep -v '^[[:space:]]*#')"
  [ -n "$body" ] || { echo "provision_remote_paths is not defined" >&2; return 1; }

  printf '%s\n' "$body" | grep -q 'assert_keys_dir_is_durable' || {
    echo "provision_remote_paths never calls the durability guard:" >&2
    printf '%s\n' "$body" >&2
    return 1
  }
}

@test "KEYS the keys directory is created and chowned on the VM" {
  local body
  body="$(sed -n '/^provision_remote_paths() {/,/^}/p' "${UP}" | grep -v '^[[:space:]]*#')"
  [ -n "$body" ] || { echo "provision_remote_paths is not defined" >&2; return 1; }

  printf '%s\n' "$body" | grep -qE 'mkdir .*REMOTE_KEYS_DIR' || {
    echo "the keys directory is never created" >&2
    return 1
  }
  printf '%s\n' "$body" | grep -qE 'chown .*REMOTE_KEYS_DIR' || {
    echo "the keys directory is created but never chowned to the pipeline user" >&2
    return 1
  }
}

@test "KEYS the keys directory is never deleted or truncated" {
  # The whole value of this directory is that its CONTENTS persist. An rm, or an
  # `install -m` (which truncates), would leave every structural assertion above
  # green while restoring the original defect exactly.
  local code
  code="$(grep -v '^[[:space:]]*#' "${UP}")"
  [ -n "$code" ] || { echo "stripped every line of ${UP}" >&2; return 1; }

  printf '%s\n' "$code" | grep -E 'rm -rf .*REMOTE_KEYS_DIR|rm -f .*REMOTE_KEYS_DIR|install .*REMOTE_KEYS_DIR' && {
    echo "something deletes or truncates the persistent keys directory" >&2
    return 1
  }
  return 0
}

@test "KEYS the driver sends DEMO_KEYS_DIR to the pipeline" {
  # Extracted from the export line specifically, not the file, for the same
  # reason as the env-contract suite: this file's own header names DEMO_KEYS_DIR
  # in prose several times.
  local sent
  sent="$(sed -n "/printf -v envs '/,/^\$/p" "${UP}" \
    | grep -oE "['[:space:]]DEMO_[A-Z_]+=%q" \
    | sed -E "s/^['[:space:]]//; s/=%q\$//")"
  [ -n "$sent" ] || { echo "no exported names found at all" >&2; return 1; }

  printf '%s\n' "$sent" | grep -qx 'DEMO_KEYS_DIR' || {
    echo "the driver never sends DEMO_KEYS_DIR; the pipeline will fall back to" >&2
    echo "the delivered tree's .keys/ and the keypair dies with the checkout." >&2
    return 1
  }
}

@test "KEYS the pipeline turns DEMO_KEYS_DIR into an exported KEYS_DIR" {
  # KEYS_DIR must be EXPORTED, not merely set: signing-keys, push-local.sh,
  # bootstrap-local and the audit-anchor targets each resolve it in a separate
  # child process. A plain assignment configures none of them.
  local code
  code="$(grep -v '^[[:space:]]*#' "${PIPE}")"
  [ -n "$code" ] || { echo "stripped every line of ${PIPE}" >&2; return 1; }

  printf '%s\n' "$code" | grep -qE 'export KEYS_DIR="\$\{DEMO_KEYS_DIR\}"' || {
    echo "demo-pipeline.sh does not export KEYS_DIR from DEMO_KEYS_DIR:" >&2
    printf '%s\n' "$code" | grep -n 'KEYS_DIR' >&2
    return 1
  }
}

@test "KEYS an unset DEMO_KEYS_DIR leaves KEYS_DIR alone" {
  # The laptop and fixture-tree path. A hardcoded /opt/signalloom/keys would be
  # wrong on any machine that has no such directory, and forcing KEYS_DIR to an
  # empty string would be worse than either: scripts/lib/keys.sh treats an
  # explicit KEYS_DIR as authoritative and would resolve the signing key to
  # '/cosign.key'.
  local block
  block="$(sed -n '/^if \[\[ -n "\${DEMO_KEYS_DIR:-}" \]\]; then$/,/^fi$/p' "${PIPE}")"
  [ -n "$block" ] || {
    echo "KEYS_DIR is exported unconditionally, or the guard was reshaped:" >&2
    grep -n 'KEYS_DIR' "${PIPE}" >&2
    return 1
  }
  printf '%s\n' "$block" | grep -q 'export KEYS_DIR'
}

@test "KEYS the pipeline exports KEYS_DIR before the first consumer" {
  # Ordering is load-bearing and cheap to get wrong. `make signing-keys` is the
  # first consumer; an export placed after it would mint into the checkout and
  # then sign from the durable directory, which fails in a way that reads as a
  # cosign problem.
  local export_line first_consumer
  export_line="$(grep -n 'export KEYS_DIR' "${PIPE}" | head -1 | cut -d: -f1)"
  first_consumer="$(grep -nE '^"\$MAKE_BIN" (signing-keys|push-local-foundation|bootstrap-local)' "${PIPE}" \
    | head -1 | cut -d: -f1)"

  [ -n "$export_line" ] || { echo "KEYS_DIR is never exported" >&2; return 1; }
  [ -n "$first_consumer" ] || { echo "no make consumer of the keys found" >&2; return 1; }

  [ "$export_line" -lt "$first_consumer" ] || {
    echo "KEYS_DIR is exported at line ${export_line}, after the first consumer at ${first_consumer}" >&2
    return 1
  }
}

@test "KEYS no key material can reach git" {
  # .keys/ is gitignored and the payload is `git archive HEAD`, so this is the
  # third line rather than the first. It is here because this change is the one
  # that moves key material around, and "nothing tracked" is exactly the kind of
  # property that is true until one day it is not.
  cd "${REPO_ROOT}"
  local tracked
  tracked="$(git ls-files | grep -E '(^|/)\.keys/|\.key$|cosign\.key|(^|/)[^/]*\.pem$' || true)"
  [ -z "$tracked" ] || {
    echo "key material is TRACKED in git:" >&2
    printf '%s\n' "$tracked" >&2
    return 1
  }
}

@test "KEYS the tracked-material check can actually see a key (no vacuous pass)" {
  # The assertion above is an absence check over `git ls-files`, and absence is
  # what an empty repo, a broken git, or a typo'd pattern all look like. This
  # proves the pattern matches the thing it is looking for.
  local probe
  probe="$(printf '%s\n' \
    ".keys/cosign.key" \
    "some/path/.keys/cosign.pub" \
    "deploy/witness.pem" \
    "src/main.go" \
    | grep -E '(^|/)\.keys/|\.key$|cosign\.key|(^|/)[^/]*\.pem$' || true)"

  [ "$(printf '%s\n' "$probe" | grep -c .)" -eq 3 ] || {
    echo "the tracked-key pattern does not match known key paths; it matched:" >&2
    printf '%s\n' "$probe" >&2
    return 1
  }
  printf '%s\n' "$probe" | grep -q 'src/main.go' && {
    echo "the pattern matches ordinary source files" >&2
    return 1
  }
  return 0
}

@test "KEYS both scripts are syntactically valid" {
  run bash -n "${UP}"
  [ "$status" -eq 0 ]
  run bash -n "${PIPE}"
  [ "$status" -eq 0 ]
}
