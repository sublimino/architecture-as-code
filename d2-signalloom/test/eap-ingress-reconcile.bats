#!/usr/bin/env bats
# ==============================================================================
# d2-signalloom/test/eap-ingress-reconcile.bats
# Contract and integration test suite for EAP bootstrap, ingress reconciler,
# and post-teardown garbage collector.
# ==============================================================================

setup() {
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export SCRIPT_DIR="$REPO_ROOT/scripts/eap"
  export TEST_TMP_DIR="/tmp/bats-eap-ingress-$$"
  mkdir -p "$TEST_TMP_DIR"
  export TAILSCALE_MOCK=1
  export TAILSCALE_MOCK_DIR="$TEST_TMP_DIR/mock"
  mkdir -p "$TAILSCALE_MOCK_DIR"
  export SIGNAL_LOOM_EAP_SALT="test-eap-salt-2026"
}

teardown() {
  rm -rf "$TEST_TMP_DIR"
}

# ── Bootstrap Script Contract ────────────────────────────────────────────────

@test "bootstrap-eap-env --dry-run outputs plan for kusari" {
  run "$SCRIPT_DIR/bootstrap-eap-env.sh" --dry-run kusari
  [ "$status" -eq 0 ]
  [[ "$output" == *'"dry_run": true'* ]]
  [[ "$output" == *'"customer_hash": "a0314bec"'* ]]
  [[ "$output" == *'"hostname": "sl-eap-a0314bec"'* ]]
  [[ "$output" == *'"namespace": "eap-a0314bec"'* ]]
}

@test "bootstrap-eap-env rejects empty company name with exit 2" {
  run "$SCRIPT_DIR/bootstrap-eap-env.sh" ""
  [ "$status" -eq 2 ]
  [[ "$output" == *"Company name cannot be empty"* ]]
}

@test "bootstrap-eap-env provisions mock state cleanly" {
  run "$SCRIPT_DIR/bootstrap-eap-env.sh" kusari
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status": "provisioned"'* ]]
  [ -f "$TAILSCALE_MOCK_DIR/sl-eap-a0314bec/state.json" ]
  [ -f "$TAILSCALE_MOCK_DIR/sl-eap-a0314bec/serve.json" ]
}

# ── Ingress Reconciler Contract ──────────────────────────────────────────────

@test "reconcile-eap-ingress --dry-run reports in_sync when actual matches desired" {
  # Seed mock node with both state and serve
  "$SCRIPT_DIR/bootstrap-eap-env.sh" kusari >/dev/null
  run "$SCRIPT_DIR/reconcile-eap-ingress.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'"in_sync": true'* ]]
  [[ "$output" == *'"desired_count": 1'* ]]
}

@test "reconcile-eap-ingress --dry-run detects missing serve route" {
  # Node exists with state.json but missing serve.json
  mkdir -p "$TAILSCALE_MOCK_DIR/sl-eap-a0314bec"
  cat > "$TAILSCALE_MOCK_DIR/sl-eap-a0314bec/state.json" <<EOF
{"hostname": "sl-eap-a0314bec", "customer_hash": "a0314bec", "mock": true}
EOF
  run "$SCRIPT_DIR/reconcile-eap-ingress.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'"in_sync": false'* ]]
  [[ "$output" == *'"missing_routes": ["a0314bec"]'* ]]
}

@test "reconcile-eap-ingress fixes missing route and converges" {
  mkdir -p "$TAILSCALE_MOCK_DIR/sl-eap-a0314bec"
  cat > "$TAILSCALE_MOCK_DIR/sl-eap-a0314bec/state.json" <<EOF
{"hostname": "sl-eap-a0314bec", "customer_hash": "a0314bec", "mock": true}
EOF
  run "$SCRIPT_DIR/reconcile-eap-ingress.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ingress reconciliation complete and verified"* ]]
  [ -f "$TAILSCALE_MOCK_DIR/sl-eap-a0314bec/serve.json" ]
}

# ── Garbage Collector Residual Detector Contract ────────────────────────────

@test "gc-eap-env reports NO_RESIDUE and exits 0 on clean state" {
  run "$SCRIPT_DIR/gc-eap-env.sh" --hash a0314bec
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO_RESIDUE: No residual resources found"* ]]
}

@test "gc-eap-env detects residual mock state, removes it, and exits 1" {
  # Create residual state
  mkdir -p "$TAILSCALE_MOCK_DIR/sl-eap-a0314bec"
  cat > "$TAILSCALE_MOCK_DIR/sl-eap-a0314bec/state.json" <<EOF
{"hostname": "sl-eap-a0314bec", "mock": true}
EOF

  run "$SCRIPT_DIR/gc-eap-env.sh" --hash a0314bec
  [ "$status" -eq 1 ]
  [[ "$output" == *"RESIDUAL_FOUND: 1 residual item(s) cleaned up"* ]]
  [ ! -d "$TAILSCALE_MOCK_DIR/sl-eap-a0314bec" ]

  # Subsequent GC run must exit 0 cleanly
  run "$SCRIPT_DIR/gc-eap-env.sh" --hash a0314bec
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO_RESIDUE: No residual resources found"* ]]
}
