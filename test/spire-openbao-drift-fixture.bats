#!/usr/bin/env bats

# The one input on which a naive drift guard goes green.
#
# OFFLINE and fixture-driven, deliberately. Its sibling
# test/spire-openbao-trust-drift.bats is the LIVE stage (6e) and answers "does
# this estate agree with itself right now". This suite answers a different and
# narrower question: "does the comparison ask about MEMBERSHIP or about
# ARITHMETIC". That is entirely inside scripts/lib/spire-trust-anchor.sh, so a
# stub can settle it — and because it needs no cluster it runs in the static
# tier, seconds after checkout, where it also guards the library against a
# future simplification.
#
# Neither suite substitutes for the other. A stub only ever proves the caller's
# half; the estate is proved at stage 6e.
#
# ── The fixtures are real, not invented ────────────────────────────────────
#
# Captured verbatim on 2026-08-23 from kind-osramp, a lane that had drifted on
# its own after 8 days of uptime. Nothing here was manufactured or aged
# artificially:
#
#     SPIRE published : 5 JWT-SVID keys
#     OpenBao held    : 5 keys
#     in common       : 1  -- and it was NEITHER the active NOR the prepared
#                            authority, just a stale survivor
#     active authority: k9rpotNxjuNX1vsLXOu4yq3oqdJRJ6Ve, ABSENT from OpenBao
#
# Every SPIFFE login on that lane was failing, and the key COUNTS matched
# exactly. They still matched after the repair — 5 before, 5 after — so the
# count never moved through the entire outage and recovery. That is the whole
# point of this file: the obvious implementation of this guard, comparing
# lengths, is green in every one of those states.
#
# Public keys only. No private material and no tokens are in the fixtures.

FIXTURES="test/fixtures/spire-openbao-drift"

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  # shellcheck source=scripts/lib/spire-trust-anchor.sh
  source "$root/scripts/lib/spire-trust-anchor.sh"

  stub="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub"
  # Stands in for the two reads the library makes. Anything it does not
  # recognise exits 64 rather than returning empty, so a change to the library's
  # kubectl invocations surfaces as a loud failure here instead of silently
  # feeding the comparison nothing — which would make every assertion below
  # vacuous in exactly the way this suite exists to prevent.
  cat >"$stub/kubectl" <<SCRIPT
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *'bundle show'*)          cat "$root/$FIXTURES/spire-bundle-drifted.json" ;;
  *'auth/jwt/config'*)      cat "$root/$FIXTURES/openbao-config-drifted.json" ;;
  *'localauthority jwt show'*)
    printf 'Active JWT authority:\n  Authority ID: k9rpotNxjuNX1vsLXOu4yq3oqdJRJ6Ve\n  Expires at: 2026-08-24 02:34:38 +0000 UTC\n\n'
    printf 'Prepared JWT authority:\n  Authority ID: y0h47lUpSDwUsCcYRzsapJyNNVvqNVPK\n  Expires at: 2026-08-24 14:34:48 +0000 UTC\n'
    ;;
  *) printf 'unexpected kubectl invocation: %s\n' "\$args" >&2; exit 64 ;;
esac
SCRIPT
  chmod +x "$stub/kubectl"
  PATH="$stub:$PATH"
}

# The assertion that gives this suite its reason to exist.
#
# If this ever fails it does NOT mean the fixtures drifted — it means someone
# replaced set membership with a length comparison, and the guard has stopped
# being able to see the outage it was written for.
@test "DRIFT the guard goes RED when counts are EQUAL and the sets are not" {
  run assert_openbao_accepts_spire_jwt_keys inf-bao dummy-token
  [ "$status" -ne 0 ]
  [[ "$output" == *'at least one SPIRE key is absent'* ]]
}

# Asserts the premise of the test above rather than leaving it in a comment.
# Without this, "counts are equal" is a claim about the fixtures that nothing
# checks, and a fixture edit could quietly turn the test above into an ordinary
# count mismatch — still green, but no longer testing membership.
@test "DRIFT the fixture really is the count-equal case, so a length check would pass" {
  local spire_n bao_n
  spire_n="$(spire_jwt_svid_keys inf-bao | grep -c .)"
  bao_n="$(openbao_jwt_validation_keys inf-bao dummy-token | grep -c .)"
  [ "$spire_n" -eq 5 ]
  [ "$bao_n" -eq 5 ]
  [ "$spire_n" -eq "$bao_n" ]
}

# The overlap is what makes this fixture hostile rather than merely unequal. A
# guard comparing "is the intersection non-empty" — another plausible
# simplification — is ALSO green here, because exactly one key is shared.
@test "DRIFT exactly one key is shared, so a non-empty-intersection check would pass too" {
  local common
  common="$(comm -12 \
    <(spire_jwt_svid_keys inf-bao | grep . | sort -u) \
    <(openbao_jwt_validation_keys inf-bao dummy-token | grep . | sort -u) | wc -l)"
  [ "$common" -eq 1 ]
}

# The severity split. The shared key is a stale survivor, so the key SPIRE is
# actually signing with is absent and logins are failing NOW -- as opposed to a
# rotation merely being prepared, which is the ~8h warning case.
@test "DRIFT the ACTIVE authority is the one missing, so this is an outage not a warning" {
  local kid der
  kid="$(spire_active_jwt_authority_kid inf-bao)"
  [ "$kid" = "k9rpotNxjuNX1vsLXOu4yq3oqdJRJ6Ve" ]
  der="$(spire_jwt_key_der_for_kid inf-bao "$kid")"
  [ -n "$der" ]
  run bash -c "source '$root/scripts/lib/spire-trust-anchor.sh'
               openbao_jwt_validation_keys inf-bao dummy-token | grep -Fqx '$der'"
  [ "$status" -ne 0 ]
}
