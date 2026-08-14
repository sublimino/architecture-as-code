# shellcheck shell=bash
# keys.sh — resolve the signing-key directory shared by every worktree.
#
# .keys/ is gitignored, so it is per-checkout, while the Kind cluster and the
# zot registry it signs for are shared. `make signing-keys` only creates what is
# absent, so each new worktree minted its own keypair. On 2026-08-13 four were
# on disk; the cluster trusted one and refused pushes signed by the others.
#
# The refusal is hard to read, which is what made it expensive: cosign reports a
# signature made by an untrusted key with the same words it uses for an artifact
# that was never signed — "no matching signatures were found". So a key mismatch
# presents as unsigned, and the reader goes looking for a missing signature that
# is in fact present and valid. It pinned the fleet OCIRepository to a stale
# revision for hours.
#
# git already knows where the shared checkout is, so nothing needs configuring
# per worktree: --git-common-dir resolves to the MAIN worktree's .git from
# inside any linked worktree, and to its own .git from the main checkout. One
# expression, correct from everywhere.
#
# Order matters. An explicit KEYS_DIR wins so the Makefile (which exports it)
# and any deliberate override are authoritative; git is consulted only when
# nothing was passed; and the plain relative default is last.
#
# That last branch almost never fires, and it is important not to believe
# otherwise. gcp-ci.sh does tar the tree with --exclude='.git' — but
# vm-pipeline.sh runs `git init` on the VM straight after extracting it, because
# Kustomize treats .git/ as the security boundary for relative path traversal.
# So the git branch above fires on CI too, and this returns an ABSOLUTE path
# there. An earlier version of this comment asserted a CI VM has no git at all;
# that false premise made a `../$(KEYS_DIR)` concatenation in the Makefile look
# safe, and it aborted both CI lanes before stage 1. Assume absolute everywhere
# — see keys_dir_abs() below, and $(abspath …) on the make side.

keys_dir() {
  if [ -n "${KEYS_DIR:-}" ]; then
    printf '%s' "${KEYS_DIR}"
    return 0
  fi

  local common
  common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "${common}" ] && [ -d "${common}" ]; then
    printf '%s/.keys' "$(cd "${common}/.." && pwd)"
    return 0
  fi

  printf '.keys'
}

# keys_dir_abs BASE — keys_dir(), forced absolute against BASE.
#
# keys_dir() returns whichever of three sources answered, and they do not agree
# about absoluteness: an exported KEYS_DIR is whatever the caller set, the
# git-common-dir branch is always absolute, and the CI fallback is the relative
# '.keys'. A caller that changes directory before using the result therefore has
# to handle both, and every one that forgets breaks in one of two mirror-image
# ways:
#
#   * joining an ABSOLUTE value onto a base produces the nonsense path
#     /repo/root/home/andy/src/cp/osramp-demo/.keys/witness.pem -- the leading
#     slash is swallowed by the concatenation. This is what the audit-anchor
#     tamper demo did, and it only ever worked because that worktree happened to
#     contain its own .keys.
#   * passing a RELATIVE value through after `cd` into a subdirectory resolves
#     it against the subdirectory instead of the repo root.
#
# Absolute wins outright; relative is anchored to BASE. Callers that never
# change directory can keep using keys_dir() unchanged -- push-local.sh,
# admission-demo.sh, revocation-demo.sh and build-sign-dashboard.sh all do, and
# none of them are touched by this.
keys_dir_abs() {
  local base="${1:-$PWD}" dir
  dir="$(keys_dir)"
  case "${dir}" in
    /*) printf '%s' "${dir}" ;;
    *)  printf '%s/%s' "${base%/}" "${dir}" ;;
  esac
}
