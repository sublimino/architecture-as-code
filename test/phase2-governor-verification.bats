#!/usr/bin/env bats
# @id test/phase2-governor-verification.bats
# @target scripts/test-phase2-governor.sh
# @doc docs/eap/SLDC-P2-GOVERNOR-REPORT.md
# @spec Proposal - Signal Loom Local Dual-Cluster EAP Pilot Validation (SLDC-P2-GOV)
#
# SLDC-P2-GOV: multi-cluster security and fail-closed policy assertions.
#
# Tier 1 (hermetic, default): the contracts the live gates depend on, each
# paired with a deliberate mutation that must make the same check fail.
# Tier 2 (live): SLDC_P2GOV_LIVE=1 runs scripts/test-phase2-governor.sh
# against kind-osramp + kind-signalloom-hub and asserts the certificate.
#
#   bats test/phase2-governor-verification.bats
#   SLDC_P2GOV_LIVE=1 bats test/phase2-governor-verification.bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RUNNER="$REPO_ROOT/scripts/test-phase2-governor.sh"
  FIXTURE="$REPO_ROOT/test/fixtures/phase2-governor/hub-fixture.yaml"
  PROBE="$REPO_ROOT/test/fixtures/phase2-governor/workload-probe.yaml"
  RELAY="$REPO_ROOT/d2-agent-trust/spire-federation-bridge-relay.yaml"
  BOOTSTRAP="$REPO_ROOT/scripts/bootstrap-spire-federation.sh"
  ROLE="$REPO_ROOT/d2-signalloom/infra/inf-bao/configs/base/openbao-supercred-bootstrap.yaml"
  FORGE="$REPO_ROOT/scripts/lib/p2gov-forge-jwt.ts"
  TMP="$BATS_TEST_TMPDIR"
}

# --- contract checks (each is also run against a mutated input) --------------

# front nginx.conf: TLS 1.3 only, SPIFFE client verification, NodePort 31443
front_conf() { yq -e 'select(.kind == "ConfigMap" and .metadata.name == "sl-eap-front") | .data."nginx.conf"' "$1"; }
check_front_tls() {
  local conf; conf=$(front_conf "$1") || return 1
  grep -qE '^\s*ssl_protocols TLSv1\.3;\s*$' <<<"$conf" || return 1
  ! grep -qE 'TLSv1(\.[012])?[ ;]' <<<"$(grep ssl_protocols <<<"$conf")" || return 1
  grep -qE '^\s*ssl_client_certificate /svid/federated_bundle\.0\.0\.pem;' <<<"$conf" || return 1
  grep -qE '^\s*ssl_verify_client optional;' <<<"$conf" || return 1
  [ "$(yq -e 'select(.kind == "Service" and .metadata.name == "sl-eap-front") | .spec.ports[0].nodePort' "$1")" = 31443 ]
}

# relay: pure TCP pass-through (no TLS termination), bound to the bridge IP
check_relay() {
  local conf; conf=$(yq -e 'select(.kind == "ConfigMap") | .data."nginx.conf"' "$1") || return 1
  grep -q '^\s*stream {' <<<"$conf" || return 1
  ! grep -qE '^\s*(http|ssl_[a-z_]+|proxy_ssl[a-z_]*)\b' <<<"$conf" || return 1
  grep -qE 'listen \$\{SPIRE_RELAY_BIND_IP\}:\$\{SPIRE_BUNDLE_NODEPORT\};' <<<"$conf" || return 1
  [ "$(yq -e 'select(.kind == "Deployment") | .spec.template.spec.hostNetwork' "$1")" = true ]
}

# OpenBao role: glob matching on the cardvault subject prefix only
role_json() { yq -e 'select(.kind == "ConfigMap" and .metadata.name == "openbao-jwt-role-config") | .data."role.json"' "$1"; }
check_role_glob() {
  jq -e '.bound_claims_type == "glob"
         and .bound_claims.sub == "spiffe://osramp.local/ns/agent-trust/sa/agent-cardvault*"
         and (.bound_audiences | index("openbao") != null)
         and .token_no_default_policy == true' >/dev/null
}

# certification: every gate passed, human sign-off still required
check_cert() {
  jq -e '.schema == "sldc.phase2-governance-certification/v1"
         and .card == "SLDC-P2-GOV" and .status == "pass" and .hard_blocker == false
         and .human_signoff_required == true
         and ([.gates[].id] | sort) == ["G1","G2","G3","G4","G5","G6","G7","G8"]
         and all(.gates[]; .status == "pass")
         and (.integration_head | test("^[0-9a-f]{40}$"))' "$1" >/dev/null
}

# audit log: claims only, never a signed compact JWS or an OpenBao token
check_audit_redacted() {
  ! grep -qE 'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{20,}' "$1" || return 1
  ! grep -qE '"client_token":"(s|hvs|b)\.[A-Za-z0-9]' "$1"
}

# --- tier 1 ------------------------------------------------------------------------

@test "runner parses and documents gates G1-G8" {
  bash -n "$RUNNER"
  run "$RUNNER" --help
  [ "$status" -eq 0 ]
  for g in G1 G2 G3 G4 G5 G6 G7 G8; do grep -q "#   $g " "$RUNNER"; done
}

@test "runner rejects unknown options with exit 2" {
  run "$RUNNER" --no-such-flag
  [ "$status" -eq 2 ]
}

@test "legacy CRKC Phase 2 suite stays reachable behind --crkc" {
  [ -x "$REPO_ROOT/scripts/test-crkc-phase2-governor.sh" ]
  grep -q 'exec "$SCRIPT_DIR/test-crkc-phase2-governor.sh"' "$RUNNER"
}

@test "front enforces TLS 1.3 only and verifies clients against the federated bundle" {
  check_front_tls "$FIXTURE"
}

@test "MUTATION: adding TLSv1.2 to the front fails the TLS contract" {
  sed 's/ssl_protocols TLSv1.3;/ssl_protocols TLSv1.2 TLSv1.3;/' "$FIXTURE" >"$TMP/f.yaml"
  run check_front_tls "$TMP/f.yaml"
  [ "$status" -ne 0 ]
}

@test "MUTATION: dropping client-certificate verification fails the TLS contract" {
  sed '/ssl_verify_client optional;/d' "$FIXTURE" >"$TMP/f.yaml"
  run check_front_tls "$TMP/f.yaml"
  [ "$status" -ne 0 ]
}

@test "front's server identity is a hub SVID fetched from SPIRE, not a static secret" {
  run yq -e 'select(.kind == "Deployment" and .metadata.name == "sl-eap-front") | .spec.template.spec.initContainers[0].command | join(" ")' "$FIXTURE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"spire-agent api fetch x509"* ]]
  ! yq -e 'select(.kind == "Secret")' "$FIXTURE" >/dev/null 2>&1
}

@test "bundle-endpoint relay is a TLS pass-through bound to the bridge IP" {
  check_relay "$RELAY"
}

@test "MUTATION: a relay that terminates TLS fails the pass-through contract" {
  sed 's/proxy_timeout 60s;/proxy_timeout 60s;\n        ssl_certificate \/x.pem;/' "$RELAY" >"$TMP/r.yaml"
  run check_relay "$TMP/r.yaml"
  [ "$status" -ne 0 ]
}

@test "bootstrap renders the relay on 172.19.0.10:31843 and wires it into apply" {
  run bash -c "source '$BOOTSTRAP'; render_relay"
  [ "$status" -eq 0 ]
  [[ "$output" == *"listen 172.19.0.10:31843;"* ]]
  [[ "$output" == *"host: 172.19.0.10"* ]]
  grep -qE '^\s+step_relay$' "$BOOTSTRAP"
}

@test "SPIRE node alias avoids the reserved /spire/ namespace" {
  run grep -n 'spiffe://\$WORKLOAD_TD/spire/' "$BOOTSTRAP"
  [ "$status" -ne 0 ]
  grep -q 'spiffe://$WORKLOAD_TD/k8s-cluster/$WORKLOAD_CLUSTER' "$BOOTSTRAP"
}

@test "OpenBao role binds the cardvault subject prefix with glob matching" {
  role_json "$ROLE" | check_role_glob
}

@test "MUTATION: removing bound_claims_type fails the glob contract" {
  local defs; defs=$(declare -f role_json check_role_glob)
  run bash -c "$defs; role_json '$ROLE' | check_role_glob"
  [ "$status" -eq 0 ]
  run bash -c "$defs; role_json '$ROLE' | jq 'del(.bound_claims_type)' | check_role_glob"
  [ "$status" -eq 1 ]
}

@test "forged rogue.local JWT is ES256 from a fresh key every time" {
  command -v bun >/dev/null || skip "bun required"
  a=$(bun "$FORGE" spiffe://rogue.local/ns/x/sa/y signal-ingest)
  b=$(bun "$FORGE" spiffe://rogue.local/ns/x/sa/y signal-ingest)
  [ "$(tr -cd . <<<"$a" | wc -c)" -eq 2 ]
  [ "${a##*.}" != "${b##*.}" ]
  hdr=$(cut -d. -f1 <<<"$a" | basenc --base64url -d 2>/dev/null || true)
  [[ "$hdr" == *'"alg":"ES256"'* ]]
  [[ "$hdr" == *'"kid":"sldc-p2-gov-rogue"'* ]]
}

@test "OpenBao wrapper keeps the root token off every argv" {
  run grep -n 'BAO_TOKEN' "$REPO_ROOT/scripts/lib/p2gov-bao.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'BAO_TOKEN="$BAO_DEV_ROOT_TOKEN_ID" exec bao'* ]]
  if grep -qE 'BAO_TOKEN=\$\{?[A-Za-z_]+\}? *\\?$|--token' "$REPO_ROOT/scripts/lib/p2gov-bao.sh"; then return 1; fi
  # tokens reach jq/curl on stdin; none is ever passed as a --arg value
  ! grep -qE -- '--arg(json)? +[A-Za-z_]+ +"?\$\{?(tok|token|jwt|BAO_TOKEN)' "$RUNNER"
}

@test "workload probe pods carry the fixture label the cleanup trap keys on" {
  [ "$(yq -e '.metadata.labels."signalloom.io/fixture"' "$PROBE")" = true ]
  [ "$(yq -e 'select(.kind == "Namespace") | .metadata.labels."signalloom.io/fixture"' "$FIXTURE")" = true ]
}

# The runner's own audit helpers, extracted verbatim and driven offline.
runner_fn() { awk -v f="$1() {" 'index($0, f) == 1 {p = 1} p {print} p && /(^|; )}$/ {exit}' "$RUNNER"; }
jws() { printf '%s.%s.%s' "$(printf '%s' "$1" | basenc --base64url -w0 | tr -d =)" "$(printf '%s' "$2" | basenc --base64url -w0 | tr -d =)" "$(head -c 64 /dev/urandom | basenc --base64url -w0 | tr -d =)"; }

@test "runner claims(): the audit view of a JWT-SVID is header and claims, never the signature" {
  eval "$(runner_fn claims)"
  tok=$(jws '{"alg":"ES256","kid":"k"}' '{"sub":"spiffe://osramp.local/ns/agent-trust/sa/agent-cardvault-worker-1","aud":["openbao"]}')
  out=$(claims "$tok")
  [ "$(jq -c . <<<"$out")" = '{"header":{"alg":"ES256","kid":"k"},"claims":{"sub":"spiffe://osramp.local/ns/agent-trust/sa/agent-cardvault-worker-1","aud":["openbao"]}}' ]
  if grep -qF "${tok##*.}" <<<"$out"; then return 1; fi
  printf 'x: %s\n' "$out" >"$TMP/a.txt"; check_audit_redacted "$TMP/a.txt"
}

@test "runner bao_login(): client token and accessor are redacted before the body reaches the audit" {
  eval "$(runner_fn bao_login)"
  mkdir -p "$TMP/bin"; P2GOV_TMP="$TMP"; BAO_ROLE=agent-cardvault BAO_MOUNT=jwt-osramp BAO_ADDR=http://x
  cat >"$TMP/bin/curl" <<'CURL'
#!/bin/sh
cat >/dev/null
printf '{"auth":{"client_token":"s.SECRETSECRETSECRET","accessor":"acc-SECRET","policies":["agent-cardvault-policy"]}}\n200'
CURL
  chmod +x "$TMP/bin/curl"
  code=$(PATH="$TMP/bin:$PATH" bao_login eyJ.eyJ.sig)
  [ "$code" = 200 ]
  [ "$(cat "$TMP/bao_token_len")" = 20 ]
  [ "$(jq -c .auth "$TMP/bao_body")" = '{"client_token":"REDACTED","accessor":"REDACTED","policies":["agent-cardvault-policy"]}' ]
  if grep -q SECRET "$TMP/bao_body"; then return 1; fi
}

# ensure_si_image(): fake docker/kind record argv; FK_HAVE=1 means the tag exists.
si_fakes() {
  mkdir -p "$TMP/bin"; : >"$TMP/calls"
  printf '#!/bin/sh\necho "docker $*" >>"%s"\ncase "$1" in image) [ "${FK_HAVE:-0}" = 1 ];; build) [ "${FK_BUILD_FAIL:-0}" != 1 ];; esac\n' "$TMP/calls" >"$TMP/bin/docker"
  printf '#!/bin/sh\necho "kind $*" >>"%s"\n' "$TMP/calls" >"$TMP/bin/kind"
  chmod +x "$TMP/bin/docker" "$TMP/bin/kind"
  DOCKER_BIN="$TMP/bin/docker" KIND_BIN="$TMP/bin/kind" SI_IMAGE=signal-ingest:sldc-p2-gov-abc12345
  SLDC_HUB_CLUSTER=signalloom-hub AUDIT_TXT="$TMP/audit.txt" REPO_ROOT=/repo
}

@test "runner ensure_si_image(): a HEAD tag the host lacks is built from signal-ingest and loaded onto the hub" {
  eval "$(runner_fn ensure_si_image)"; si_fakes
  ensure_si_image
  [ "$(grep -c '^docker build' "$TMP/calls")" -eq 1 ]
  grep -qx 'docker build -q -t signal-ingest:sldc-p2-gov-abc12345 -f /repo/d2-signalloom/apps/signal-ingest/Dockerfile /repo/d2-signalloom/apps' "$TMP/calls"
  [ "$(tail -1 "$TMP/calls")" = "kind load docker-image --name signalloom-hub signal-ingest:sldc-p2-gov-abc12345" ]
}

@test "runner ensure_si_image(): an existing tag is loaded without a rebuild" {
  eval "$(runner_fn ensure_si_image)"; si_fakes
  FK_HAVE=1 ensure_si_image
  [ "$(grep -c '^docker build' "$TMP/calls")" -eq 0 ]
  grep -qx 'kind load docker-image --name signalloom-hub signal-ingest:sldc-p2-gov-abc12345' "$TMP/calls"
}

@test "runner ensure_si_image(): a failed build stops before loading and names the image" {
  eval "$(runner_fn ensure_si_image)"; si_fakes
  FK_BUILD_FAIL=1 run ensure_si_image
  [ "$status" -eq 1 ]
  [[ "$output" == *"docker build of signal-ingest:sldc-p2-gov-abc12345 failed"* ]]
  [ "$(grep -c '^kind' "$TMP/calls")" -eq 0 ]
}

@test "MUTATION: a certificate with one failed gate is rejected" {
  jq -n '{schema: "sldc.phase2-governance-certification/v1", card: "SLDC-P2-GOV", status: "pass", hard_blocker: false,
          human_signoff_required: true, integration_head: ("a" * 40),
          gates: [range(1; 9) | {id: "G\(.)", status: "pass"}]}' >"$TMP/c.json"
  check_cert "$TMP/c.json"
  jq '.gates[4].status = "fail"' "$TMP/c.json" >"$TMP/bad.json"
  run check_cert "$TMP/bad.json"
  [ "$status" -ne 0 ]
}

@test "MUTATION: an audit line with a raw JWT-SVID or OpenBao client token is rejected" {
  printf 'openbao login: 200 {"auth":{"client_token":"REDACTED"}}\n' >"$TMP/a.txt"
  check_audit_redacted "$TMP/a.txt"
  printf 'leak: %s\n' "$(jws '{"alg":"ES256"}' '{"sub":"spiffe://osramp.local/x"}')" >"$TMP/jwt.txt"
  run check_audit_redacted "$TMP/jwt.txt"
  [ "$status" -ne 0 ]
  printf '{"auth":{"client_token":"hvs.CAESIabc"}}\n' >"$TMP/tok.txt"
  run check_audit_redacted "$TMP/tok.txt"
  [ "$status" -ne 0 ]
}

# --- tier 2 ------------------------------------------------------------------------

live() { [[ "${SLDC_P2GOV_LIVE:-}" == 1 ]] || skip "live tier: set SLDC_P2GOV_LIVE=1"; }

@test "live: governor runner certifies Phase 2 end to end and tears its fixtures down" {
  live
  P2GOV_EVIDENCE_DIR="$TMP/ev" run "$RUNNER"
  [ "$status" -eq 0 ]
  check_cert "$TMP/ev/phase2-governance-certification.json"
  check_audit_redacted "$TMP/ev/phase2-token-exchange-audit.txt"
  run kubectl --context kind-signalloom-hub get ns sldc-p2-gov -o jsonpath='{.status.phase}'
  [ "$output" != Active ]
}

# --- runner abort path (offline: temp repo, fake kubectl, temp evidence dir) --

@test "runner: an abort mid-gates replaces a stale pass certificate with a fail one" {
  repo="$TMP/repo"; ev="$TMP/ev"; mkdir -p "$repo" "$ev" "$TMP/bin"
  g() { git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
  g init -q; g commit -q --allow-empty -m a; g commit -q --allow-empty -m b
  printf '#!/bin/sh\nexit 1\n' >"$TMP/bin/kubectl"; chmod +x "$TMP/bin/kubectl"
  echo '{"status":"pass","gates":[]}' >"$ev/phase2-governance-certification.json"
  REPO_ROOT="$repo" P2GOV_EVIDENCE_DIR="$ev" KUBECTL_BIN="$TMP/bin/kubectl" \
    P2_1_SHA="$(g rev-parse HEAD~1)" P2_2_SHA="$(g rev-parse HEAD)" SI_IMAGE=x \
    run "$RUNNER" --skip-bringup
  [ "$status" -ne 0 ]
  [[ "$output" != *"write_cert: command not found"* ]]
  [ "$(jq -r .status "$ev/phase2-governance-certification.json")" = fail ]
  [ "$(jq -r '.gates[-1].id' "$ev/phase2-governance-certification.json")" = ABORT ]
  [ "$(jq -r '.gates[0] | [.id, .status] | join(" ")' "$ev/phase2-governance-certification.json")" = "G1 pass" ]
}
