#!/usr/bin/env bats

# Does OpenBao still trust the keys SPIRE is signing JWT-SVIDs with RIGHT NOW?
#
# This is a LIVE stage. It reads SPIRE's published bundle and OpenBao's
# auth/jwt/config off the running cluster and compares them. It is deliberately
# not a stub suite: the defect it exists to catch is a divergence between two
# live artefacts, and a fake client can only ever prove that the comparison code
# runs, never that the estate agrees.
#
# ── Why this suite exists ───────────────────────────────────────────────────
#
# scripts/lib/spire-trust-anchor.sh has carried `assert_openbao_accepts_spire_
# jwt_keys` since the 2026-08-14 outage. It was invoked by exactly one caller,
# scripts/agent-trust-local.sh, and by NEITHER scripts/gcp-tf/demo-pipeline.sh
# NOR scripts/ci/vm-pipeline.sh. Every lane therefore drifted green. The
# capability existed; the hand-maintained runner lists did not name it. That is
# the fifth instance of that shape in this repo -- see the stage 1g/1h comments
# in both pipelines for the previous four.
#
# ── The arithmetic that decides the failure modes below ─────────────────────
#
# SPIRE 1.11.1, pkg/server/ca/manager/manager.go:
#     preparationThresholdDivisor = 2   -> a successor key is PREPARED and
#                                          published at ca_ttl/2
#     activationThresholdDivisor  = 6   -> it becomes ACTIVE with ca_ttl/6 of
#                                          the incumbent's life remaining,
#                                          i.e. at 5/6 of ca_ttl
#
# The lane's server.conf (d2-signalloom/infra/inf-bao/controllers/base/
# spire-openbao-config.yaml) sets no ca_ttl, so ca_ttl is SPIRE's default 24h.
# Confirmed empirically rather than assumed: `spire-server localauthority jwt
# show` on a live lane reported an active authority expiring at 02:34:38 and a
# prepared one at 14:34:48 -- a 12h00m10s gap, which is ca_ttl/2 for ca_ttl=24h.
#
# Stated as a rule so the next person does not reach for the 24h figure and be
# wrong by four hours in the UNSAFE direction:
#
#     PREPARE at ca_ttl/2        BREAK at ca_ttl*5/6
#
# So with a 24h ca_ttl the timeline after a sync is:
#     t+12h  SPIRE publishes a second key. Logins still work.
#     t+20h  SPIRE starts SIGNING with it. EVERY login fails.
#
# ── Why no interval is written down anywhere ───────────────────────────────
#
# server.conf sets no ca_ttl, so the rotation period is whatever the SPIRE
# BUILD defaults to. It can therefore change on an image bump with no config
# change and no review — a periodic re-sync tuned to today's 24h would silently
# become wrong the day SPIRE ships a different default. That is an argument
# against choosing an interval at all rather than against any particular one,
# and it is why this file asserts AGREEMENT between the two live artefacts and
# never a duration. Nothing here needs updating if ca_ttl changes.
#
# The two failure modes below map onto those two moments, and they are separated
# on purpose. "A rotation is pending" is an 8-hour warning; "the active key is
# absent" means the identity plane is down as you read it. On 2026-08-14 nobody
# could tell those apart, and the outage was misattributed to a young planner
# pod that had nothing to do with it.
#
# ── If you ever exercise a REAL rotation, decode the token's kid ───────────
#
# The SPIRE agent CACHES JWT-SVIDs. For roughly a minute after
# `localauthority jwt activate`, a workload still presents a token signed by the
# PREVIOUS authority — so a login succeeds, and it tells you nothing about the
# rotation you just triggered.
#
# Measured 2026-08-23: an activate-then-login test PASSED and was nearly
# reported as "live-JWKS survives rotation". It was invalid. Decoding the token
# header showed `kid` was still the OLD authority. The control arm passed for
# the same wrong reason, so the two agreed and both were meaningless. Only after
# the agent's cache turned over (t+1min, kid flipped) did the arms separate:
# snapshot FAILED with "no known key successfully validated the token
# signature", live-JWKS SUCCEEDED.
#
# So: a rotation test that checks only the login's exit status proves nothing.
# Assert which kid signed the token before believing either outcome:
#
#   cut -d. -f1 <jwt> | tr '_-' '/+' | base64 -d    # -> {"alg":"ES256","kid":...}
#
# This suite compares SPIRE's published bundle against OpenBao's config and
# never mints a token, so it is not exposed to the caching. The warning is here
# because this is where someone will come to add a rotation test.
#
# ── The trap this suite must not fall into ─────────────────────────────────
#
# Do NOT reduce any of this to a count comparison. Measured on a drifted lane
# while writing this suite:
#
#     SPIRE publishes : 5 jwt-svid keys
#     OpenBao holds   : 5 keys
#     in common       : 1  (and it was neither the active nor the prepared one)
#
# Equal counts, near-disjoint sets, every login failing. A count check is green
# there. Membership is the only question worth asking, which is why every
# assertion below goes through the shared canonicaliser in spire-trust-anchor.sh
# rather than comparing lengths.

BAO_NAMESPACE="${BAO_NAMESPACE:-inf-bao}"
BAO_ROOT_TOKEN="${BAO_ROOT_TOKEN:-signalloom-demo-root-token}"

setup_file() {
  export ANCHOR_ROOT="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
}

setup() {
  root="$ANCHOR_ROOT"
  # shellcheck source=scripts/lib/spire-trust-anchor.sh
  source "$root/scripts/lib/spire-trust-anchor.sh"
}

# Reachability is asserted, never skipped.
#
# A `skip` here would be the all-skip trap: this suite is registered in two
# pipelines that both guarantee a converged cluster by the time it runs, so
# "cannot reach the cluster" is a lane failure, not an excuse to report nothing.
# A suite that skips its way to green in the one environment it was written for
# is worse than an absent suite, because it reads as coverage.
@test "SPIRE server is reachable and publishes at least one JWT-SVID key" {
  run spire_jwt_svid_keys "$BAO_NAMESPACE"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "OpenBao's JWT auth mount holds at least one validation key" {
  # Catches the never-synced and the wiped-config cases, which the membership
  # test below cannot distinguish from a total rotation on its own. An empty
  # auth/jwt/config fails every login exactly like a drifted one.
  run openbao_jwt_validation_keys "$BAO_NAMESPACE" "$BAO_ROOT_TOKEN"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# CRITICAL: this is the "the identity plane is down right now" test.
#
# Only the ACTIVE authority signs SVIDs, so its absence from OpenBao is the
# precise condition under which every SPIFFE login is failing at this instant.
# The kid SPIRE reports as its active authority is the same string the bundle
# publishes as that key's `kid` -- verified against a live lane.
@test "the JWT authority SPIRE is signing with is present in OpenBao" {
  local active_kid der
  # Both reads go through scripts/lib/spire-trust-anchor.sh rather than kubectl
  # here: test/no-exec-probes-in-tests.bats bans exec probes in test files, and
  # the ban is right — a kubectl that fails inside a test is indistinguishable
  # from the property failing. The library's readers return non-zero on a failed
  # exec, so `run` + a status check tells those two apart.
  run spire_active_jwt_authority_kid "$BAO_NAMESPACE"
  [ "$status" -eq 0 ]
  active_kid="$output"
  [ -n "$active_kid" ]

  run spire_jwt_key_der_for_kid "$BAO_NAMESPACE" "$active_kid"
  [ "$status" -eq 0 ]
  der="$output"
  [ -n "$der" ]

  openbao_jwt_validation_keys "$BAO_NAMESPACE" "$BAO_ROOT_TOKEN" >"$BATS_TEST_TMPDIR/bao.txt"
  if ! grep -Fqx "$der" "$BATS_TEST_TMPDIR/bao.txt"; then
    printf 'ACTIVE SPIRE JWT authority %s is ABSENT from OpenBao auth/jwt/config.\n' "$active_kid" >&2
    printf 'Every SPIFFE->OpenBao login is failing NOW with "no known key successfully validated the token signature".\n' >&2
    printf 'Affected roles: agent-trust-planner, agent-trust-triage, signalloom-cardvault-agent, signalloom-fe-signalloom.\n' >&2
    printf 'Re-sync with: sync_openbao_jwt_validation %s <root-token> (scripts/lib/spire-trust-anchor.sh)\n' "$BAO_NAMESPACE" >&2
    return 1
  fi
}

# EARLY WARNING: fires at ca_ttl/2, roughly 8 hours before the outage above.
#
# This is the existing library assert, unchanged, invoked for the first time by
# a pipeline. It is stricter than strictly necessary -- a login only needs the
# active key -- and that strictness is the point: it converts a silent 8-hour
# fuse into a red stage.
# FALSIFICATION, and the reason this suite is not purely live.
#
# Everything above needs a cluster. This one must not, because it guards the
# property that made the assert above worth wiring in at all: that it can FAIL.
#
# Until 2026-08-23 it could not. `mapfile -t arr < <(cmd) || return 1` reports
# mapfile's status and never cmd's, so an unreachable SPIRE left the key list
# empty, the membership loop never ran, and the function returned 0. Verified
# with KUBECONFIG=/nonexistent before the fix: the assert PASSED against no
# cluster. Wiring that version into two pipelines would have added two stages
# incapable of going red -- coverage on paper, nothing underneath.
#
# scripts/check-vacuous-assertions.sh does NOT catch this shape; it reported
# 0 findings across 623 files with the vacuous version in the tree, and says so
# itself ("a check can still be hollow in a seventh way"). Hence a hand-written
# falsification rather than reliance on the lint.
@test "the trust assert FAILS when it cannot read the cluster" {
  local stub="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub"
  # Every read in the library goes through kubectl. A kubectl that always fails
  # is exactly the unreachable-cluster case, without needing a cluster to break.
  printf '#!/usr/bin/env bash\nexit 1\n' >"$stub/kubectl"
  chmod +x "$stub/kubectl"

  run env PATH="$stub:$PATH" bash -c "
    source '$root/scripts/lib/spire-trust-anchor.sh'
    assert_openbao_accepts_spire_jwt_keys '$BAO_NAMESPACE' '$BAO_ROOT_TOKEN'
  "
  [ "$status" -ne 0 ]
}

@test "OpenBao accepts every JWT-SVID key SPIRE currently publishes" {
  run assert_openbao_accepts_spire_jwt_keys "$BAO_NAMESPACE" "$BAO_ROOT_TOKEN"
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    printf 'A SPIRE key rotation is pending or complete and OpenBao holds a stale snapshot.\n' >&2
    printf 'If the active-authority test above PASSED, logins still work and this is an ~8h warning (SPIRE prepares at ca_ttl/2 = 12h, activates at 5/6 ca_ttl = 20h).\n' >&2
    printf 'If it FAILED, the identity plane is already down.\n' >&2
    return 1
  fi
}
