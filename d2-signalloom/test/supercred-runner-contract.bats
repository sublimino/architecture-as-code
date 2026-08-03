#!/usr/bin/env bats
#
# Token-validation parity between fe-signalloom and supercred-demo-runner.
#
# These are STATIC checks — no cluster, no tokens, no network. They belong in
# the stage-1 contract suite precisely because the defect they cover is
# invisible at runtime until someone publishes a public origin.
#
# The defect, observed 2026-08-03 on a live demo: clicking "Refresh clients"
# returned 401 invalid_token on every /demo-api/ route. Both deployments
# validate the SAME tokens minted by the SAME Dex, but only fe-signalloom
# carried API_JWT_ISSUER. The runner fell through to config.py's default —
# the in-cluster Dex service URL — while Dex was minting `iss` =
# PUBLIC_ORIGIN/dex because a tunnel was up. Every token was structurally
# valid and every token was rejected.
#
# What makes this worth a static test rather than trusting the runtime suite:
#
#   1. It is silent until a tunnel exists. With PUBLIC_ORIGIN unset both
#      deployments resolve to the same default, so the drift is invisible on
#      a laptop and on CI, and only appears when the demo is published — i.e.
#      in front of an audience.
#   2. supercred-demo-api.bats DOES cover the 401/403/200 behaviour, but it
#      needs a running cluster, so it is excluded from the static stage and
#      skips loudly when the slice is absent. A skipped test guards nothing
#      at commit time.
#   3. The two env blocks are deliberately duplicated rather than shared (see
#      the comment in the runner's deployment.yaml). Duplication is the right
#      call there, but duplication without an equality assertion is exactly
#      how the two silently diverged.
#
# So: assert the values are EQUAL, and assert they are equal *as written* —
# comparing the raw `${PUBLIC_ORIGIN:=...}` template rather than a resolved
# value. That proves both track the same substitution variable AND the same
# default. Comparing resolved values would go green on two deployments that
# happened to agree today and drift the moment the default changed in one.

setup() {
  root="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  portal="$root/d2-signalloom/apps/fe-signalloom/base/deployment.yaml"
  runner="$root/d2-signalloom/apps/supercred-demo-runner/base/deployment.yaml"
}

# Value of `- name: KEY` / `value: X` from a deployment manifest. Deliberately
# does not resolve ${PUBLIC_ORIGIN:=...} — the template text IS the contract.
env_value() {
  local file="$1" key="$2"
  awk -v k="$key" '
    $0 ~ "- name: " k "$" { want = 1; next }
    want && /value:/ {
      sub(/^[[:space:]]*value:[[:space:]]*/, "")
      gsub(/^['"'"'"]|['"'"'"]$/, "")
      print; exit
    }
    want && /- name:/ { exit }
  ' "$file"
}

@test "SUPERCRED-CONTRACT both manifests exist" {
  [ -f "$portal" ]
  [ -f "$runner" ]
}

@test "SUPERCRED-CONTRACT the runner declares every token-validation variable" {
  # The whole defect was an absent variable, so absence is the first assertion.
  for key in API_JWT_ISSUER API_JWT_AUDIENCE API_JWT_AUTHORIZED_PARTY API_JWKS_URL API_SUBJECT_TENANTS; do
    run env_value "$runner" "$key"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
  done
}

@test "SUPERCRED-CONTRACT runner and portal agree on the JWT issuer, template and all" {
  portal_issuer="$(env_value "$portal" API_JWT_ISSUER)"
  runner_issuer="$(env_value "$runner" API_JWT_ISSUER)"
  [ -n "$portal_issuer" ]
  [ "$runner_issuer" = "$portal_issuer" ]
}

@test "SUPERCRED-CONTRACT the issuer is origin-aware, not a hardcoded host" {
  # A literal host here is the same bug wearing a different hat: it would work
  # until the demo moved, then reject every token with no diagnosis.
  runner_issuer="$(env_value "$runner" API_JWT_ISSUER)"
  case "$runner_issuer" in
    *'${PUBLIC_ORIGIN'*) ;;
    *) echo "runner API_JWT_ISSUER is not origin-aware: $runner_issuer"; return 1 ;;
  esac
  case "$runner_issuer" in
    */dex) ;;
    *) echo "runner API_JWT_ISSUER must end in /dex: $runner_issuer"; return 1 ;;
  esac
}

@test "SUPERCRED-CONTRACT runner and portal agree on audience and authorized party" {
  for key in API_JWT_AUDIENCE API_JWT_AUTHORIZED_PARTY; do
    p="$(env_value "$portal" "$key")"
    r="$(env_value "$runner" "$key")"
    [ -n "$p" ]
    [ "$r" = "$p" ]
  done
}

@test "SUPERCRED-CONTRACT JWKS is fetched in-cluster by both, never over the public origin" {
  # Signature keys must come from the cluster-local Dex Service. Pointing this
  # at PUBLIC_ORIGIN would make validation depend on egress to the internet
  # and on the tunnel's cookie gate returning JSON — it returns an HTML gate
  # page, so every validation would fail in a way that reads like a bad token.
  p="$(env_value "$portal" API_JWKS_URL)"
  r="$(env_value "$runner" API_JWKS_URL)"
  [ "$r" = "$p" ]
  case "$r" in
    http://dex.inf-signalloom.svc.cluster.local:5556/dex/keys) ;;
    *) echo "API_JWKS_URL must be the in-cluster Dex Service: $r"; return 1 ;;
  esac
  case "$r" in
    *'${PUBLIC_ORIGIN'*) echo "API_JWKS_URL must NOT track PUBLIC_ORIGIN: $r"; return 1 ;;
  esac
}

@test "SUPERCRED-CONTRACT the runner maps Dex's connector-encoded subject, not just the raw userID" {
  # Dex sets `sub` to a connector-encoded id, not the bare username. A runner
  # that only knows "demo-user" survives issuer validation and then dies at
  # tenant_forbidden 403 — a second failure mode that looks nothing like the
  # first and has bitten this slice before.
  tenants="$(env_value "$runner" API_SUBJECT_TENANTS)"
  case "$tenants" in
    *CglkZW1vLXVzZXISBWxvY2Fs*) ;;
    *) echo "runner API_SUBJECT_TENANTS lacks Dex's encoded subject: $tenants"; return 1 ;;
  esac
}

@test "SUPERCRED-CONTRACT the runner keeps a non-superadmin identity so the gate is provable" {
  # A superadmin gate that no unprivileged identity ever exercises is an
  # untested gate. viewer must map to a tenant, so a 403 is unambiguously the
  # superadmin check firing rather than a missing tenant mapping.
  tenants="$(env_value "$runner" API_SUBJECT_TENANTS)"
  case "$tenants" in
    *viewer*) ;;
    *) echo "runner API_SUBJECT_TENANTS lacks a non-superadmin identity: $tenants"; return 1 ;;
  esac
}
