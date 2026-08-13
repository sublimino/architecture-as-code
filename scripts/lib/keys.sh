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
# nothing was passed; and the plain relative default is last. That default is
# not vestigial — gcp-ci.sh tars the tree with --exclude='.git', so a CI VM has
# no git at all. There it is a single checkout building its own cluster, keys
# and cluster created together in the same `make up`, so `.keys` is right.

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
