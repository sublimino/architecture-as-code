#!/usr/bin/env bats
# @id test/federation-bao-role-glob.bats
# @target d2-signalloom/infra/inf-bao/configs/base/openbao-supercred-bootstrap.yaml
# @lib test/fixtures/phase2-governor/bao-glob
#
# SLDC-P2-2: evaluate the shipped OpenBao JWT role's bound_claims.sub glob
# against adversarial SPIFFE IDs using OpenBao's own glob library
# (ryanuber/go-glob v1.0.0, same h1 hash as openbao 2.1.1 and 2.7.0 link).
# Offline: no OpenBao, no cluster. The live tier of
# spire-federation-openbao-jwt.bats proves the same library is in the path.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
ROLE_FILE="$REPO_ROOT/d2-signalloom/infra/inf-bao/configs/base/openbao-supercred-bootstrap.yaml"
GLOB_DIR="$REPO_ROOT/test/fixtures/phase2-governor/bao-glob"

setup_file() {
  export GLOB_BIN="$BATS_FILE_TMPDIR/bao-glob"
  (cd "$GLOB_DIR" && GOPROXY=off GOFLAGS=-mod=mod go build -o "$GLOB_BIN" .)
  PATTERN="$(yq -e 'select(.metadata.name == "openbao-jwt-role-config") | .data."role.json"' "$ROLE_FILE" | jq -er '.bound_claims.sub')"
  export PATTERN
}

verdict() { printf '%s\n' "$1" | "$GLOB_BIN" "$PATTERN" | cut -f1; }

@test "glob admits the cardvault service account and its prefixed siblings" {
  for sub in \
    spiffe://osramp.local/ns/agent-trust/sa/agent-cardvault \
    spiffe://osramp.local/ns/agent-trust/sa/agent-cardvault-worker-1; do
    [ "$(verdict "$sub")" = match ] || { echo "rejected: $sub"; return 1; }
  done
}

@test "glob refuses other trust domains, namespaces, and service accounts" {
  for sub in \
    spiffe://osramp.local/ns/fe-signalloom-agents/sa/kusari-agent \
    spiffe://osramp.local/ns/fe-signalloom-agents/sa/agent-cardvault \
    spiffe://osramp.local/ns/agent-trust-evil/sa/agent-cardvault \
    spiffe://osramp.local/ns/agent-trust/sa/agent-cardvaul \
    spiffe://osramp.local/ns/agent-trust/sa/evil-agent-cardvault \
    spiffe://osramp.local.evil/ns/agent-trust/sa/agent-cardvault \
    spiffe://evil/osramp.local/ns/agent-trust/sa/agent-cardvault \
    spiffe://signalloom.hub/ns/agent-trust/sa/agent-cardvault \
    spiffe://OSRAMP.LOCAL/ns/agent-trust/sa/agent-cardvault \
    SPIFFE://osramp.local/ns/agent-trust/sa/agent-cardvault \
    spiffe://osramp.local/ns/agent-trust/sa/Agent-Cardvault \
    spiffe://osrаmp.local/ns/agent-trust/sa/agent-cardvault \
    " spiffe://osramp.local/ns/agent-trust/sa/agent-cardvault" \
    spiffe://osramp.local//ns/agent-trust/sa/agent-cardvault \
    ""; do
    [ "$(verdict "$sub")" = nomatch ] || { echo "admitted: $sub"; return 1; }
  done
}

# Residual, pinned so it is visible: go-glob's '*' spans '/', so the role
# alone does not stop extra path segments. The bound is SPIRE's registration
# template (ns/{ns}/sa/{sa}; a Kubernetes SA name cannot contain '/').
@test "residual: the trailing '*' also spans path segments" {
  [ "$(verdict spiffe://osramp.local/ns/agent-trust/sa/agent-cardvault/../../ns/evil/sa/x)" = match ]
  [ "$(verdict 'spiffe://osramp.local/ns/agent-trust/sa/agent-cardvault?x=1')" = match ]
}
