#!/usr/bin/env bats
#
# @id      sl-local-deploy
# @target  .agents/skills/sl-local-deploy/Tools/local-deploy.sh
#
# Tests for local-deploy.sh:
# 1. Staleness check non-zero exit propagation (1 or 2)
# 2. Node CRI image preflight verification & abort before rollout
# 3. Dynamic workload auto-detection (signal-ingest, pkg/obscel, discovered apps)
# 4. signal-ingest dirty build refusal handling with actionable instructions

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  script="${repo_root}/.agents/skills/sl-local-deploy/Tools/local-deploy.sh"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"

  export CALL_LOG="$BATS_TEST_TMPDIR/calls.log"
  : >"$CALL_LOG"

  # Defaults for fake tools
  export FAKE_CLUSTER_INFO_STATUS=0
  export FAKE_DOCKER_INSPECT_STATUS=0
  export FAKE_STALENESS_STATUS=0
  export FAKE_INGEST_TAG_STATUS=0
  export FAKE_CURL_STATUS=0
  export MISSING_IMAGE_PATTERN=""
  export FORCE_SYNC_KUSTOMIZE=false
  export OVERRIDE_DIFF_PATHS=""

  # Fake kubectl
  cat >"$bin/kubectl" <<-'FAKE'
    #!/usr/bin/env bash
    echo "kubectl $*" >>"${CALL_LOG}"
    case "$*" in
      "cluster-info"*)
        exit "${FAKE_CLUSTER_INFO_STATUS:-0}"
        ;;
      *"kustomize"*)
        cat <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dashboard-signalloom
spec:
  template:
    spec:
      containers:
        - name: dashboard
          image: zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/dashboard-signalloom:src-0e6ebee2671f37c3
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: signal-ingest
spec:
  template:
    spec:
      containers:
        - name: signal-ingest
          image: zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/signal-ingest:src-ebf6397aa227ff2d
EOF
        exit 0
        ;;
      *"rollout restart"*)
        exit 0
        ;;
      *"rollout status"*)
        exit 0
        ;;
      *"port-forward"*)
        exit 0
        ;;
      *"get deployment"*)
        exit 0
        ;;
    esac
    exit 0
FAKE
  chmod +x "$bin/kubectl"
  export KUBECTL_BIN="$bin/kubectl"

  # Fake docker
  cat >"$bin/docker" <<-'FAKE'
    #!/usr/bin/env bash
    echo "docker $*" >>"${CALL_LOG}"
    if [[ "$*" == *"crictl inspecti"* ]]; then
      if [[ -n "${MISSING_IMAGE_PATTERN:-}" && "$*" == *"${MISSING_IMAGE_PATTERN}"* ]]; then
        exit 1
      fi
      exit "${FAKE_DOCKER_INSPECT_STATUS:-0}"
    fi
    exit 0
FAKE
  chmod +x "$bin/docker"
  export DOCKER_BIN="$bin/docker"

  # Fake make
  cat >"$bin/make" <<-'FAKE'
    #!/usr/bin/env bash
    echo "make $*" >>"${CALL_LOG}"
    exit 0
FAKE
  chmod +x "$bin/make"
  export MAKE_BIN="$bin/make"

  # Fake curl
  cat >"$bin/curl" <<-'FAKE'
    #!/usr/bin/env bash
    echo "curl $*" >>"${CALL_LOG}"
    exit "${FAKE_CURL_STATUS:-0}"
FAKE
  chmod +x "$bin/curl"
  export CURL_BIN="$bin/curl"

  # Fake check-deployed-staleness.sh
  cat >"$bin/check-deployed-staleness.sh" <<-'FAKE'
    #!/usr/bin/env bash
    echo "check-deployed-staleness $*" >>"${CALL_LOG}"
    if [[ "${FAKE_STALENESS_STATUS:-0}" -ne 0 ]]; then
      echo "STALE: workload is running older code" >&2
      exit "${FAKE_STALENESS_STATUS}"
    fi
    echo "fresh: all workloads verified"
    exit 0
FAKE
  chmod +x "$bin/check-deployed-staleness.sh"
  export CHECK_STALENESS_BIN="$bin/check-deployed-staleness.sh"

  # Fake signal-ingest-image-tag.sh
  cat >"$bin/signal-ingest-image-tag.sh" <<-'FAKE'
    #!/usr/bin/env bash
    echo "signal-ingest-image-tag $*" >>"${CALL_LOG}"
    if [[ "${FAKE_INGEST_TAG_STATUS:-0}" -ne 0 ]]; then
      echo "signal-ingest-image-tag: refusing a -dirty build; inputs that are not the committed source (modified, untracked or ignored):" >&2
      echo "!! d2-signalloom/apps/signal-ingest/cmd/main.go" >&2
      exit 1
    fi
    echo "src-ebf6397aa227ff2d"
    exit 0
FAKE
  chmod +x "$bin/signal-ingest-image-tag.sh"
  export SIGNAL_INGEST_TAG_BIN="$bin/signal-ingest-image-tag.sh"

  # Fake build-sign-dashboard.sh
  cat >"$bin/build-sign-dashboard.sh" <<-'FAKE'
    #!/usr/bin/env bash
    echo "build-sign-dashboard $*" >>"${CALL_LOG}"
    exit 0
FAKE
  chmod +x "$bin/build-sign-dashboard.sh"
  export BUILD_DASHBOARD_BIN="$bin/build-sign-dashboard.sh"

  # Fake build-sign-docs.sh
  cat >"$bin/build-sign-docs.sh" <<-'FAKE'
    #!/usr/bin/env bash
    echo "build-sign-docs $*" >>"${CALL_LOG}"
    exit 0
FAKE
  chmod +x "$bin/build-sign-docs.sh"
  export BUILD_DOCS_BIN="$bin/build-sign-docs.sh"

  # Fake kind-load-verified.sh
  cat >"$bin/kind-load-verified.sh" <<-'FAKE'
    #!/usr/bin/env bash
    echo "kind-load-verified $*" >>"${CALL_LOG}"
    exit 0
FAKE
  chmod +x "$bin/kind-load-verified.sh"
  export KIND_LOAD_VERIFIED_BIN="$bin/kind-load-verified.sh"

  PATH="$bin:$PATH"
  export PATH
}

# ─── Test 1: Staleness check exit code propagation ───────────────────────────

@test "staleness proof exit 1 propagates failure and aborts completion" {
  export FAKE_STALENESS_STATUS=1
  run "$script" -w dashboard --no-reconcile
  [ "$status" -eq 1 ]
  [[ "$output" =~ "ERROR: Deployed staleness proof failed with exit code 1" ]]
  [[ "$output" != *"Deployment Complete!"* ]]
}

@test "staleness proof exit 2 propagates cannot-verify failure and aborts completion" {
  export FAKE_STALENESS_STATUS=2
  run "$script" -w dashboard --no-reconcile
  [ "$status" -eq 2 ]
  [[ "$output" =~ "ERROR: Deployed staleness proof failed with exit code 2" ]]
  [[ "$output" != *"Deployment Complete!"* ]]
}

# ─── Test 2: Node CRI image preflight verification ───────────────────────────

@test "missing node CRI image aborts preflight before rollout restart" {
  export MISSING_IMAGE_PATTERN="signal-ingest"
  run "$script" -w ingest --no-reconcile
  [ "$status" -eq 1 ]
  [[ "$output" =~ "ERROR: Image '" ]]
  [[ "$output" =~ "is missing from cluster node. Build and load it first." ]]
  ! grep -q "rollout restart" "$CALL_LOG"
}

@test "present node CRI image passes preflight and completes rollout" {
  run "$script" -w ingest --no-reconcile
  [ "$status" -eq 0 ]
  [[ "$output" =~ "✓ Image verified on node:" ]]
  [[ "$output" =~ "Deployment Complete!" ]]
  grep -q "rollout restart deployment/signal-ingest" "$CALL_LOG"
}

# ─── Test 3: Auto-detection recognizes workload changes ───────────────────────

@test "auto-detection selects signal-ingest when apps/signal-ingest changes" {
  export OVERRIDE_DIFF_PATHS="d2-signalloom/apps/signal-ingest/cmd/main.go"
  run "$script" -w auto --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ "- signal-ingest (Signal Fusion Ingest Service)" ]]
  [[ "$output" != *"- dashboard-signalloom (Frontend)"* ]]
}

@test "auto-detection selects signal-ingest when pkg/obscel changes" {
  export OVERRIDE_DIFF_PATHS="d2-signalloom/pkg/obscel/filter.go"
  run "$script" -w auto --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ "- signal-ingest (Signal Fusion Ingest Service)" ]]
}

@test "auto-detection dynamically discovers other modified apps under apps/" {
  export OVERRIDE_DIFF_PATHS="d2-signalloom/apps/fleet-manager/callerauth.go"
  run "$script" -w auto --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ "- fleet-manager (Discovered App)" ]]
}

# ─── Test 4: Dirty build refusal handling ────────────────────────────────────

@test "signal-ingest dirty build refusal emits clear actionable message" {
  export FAKE_INGEST_TAG_STATUS=1
  export FORCE_SYNC_KUSTOMIZE=true
  run "$script" -w ingest --no-reconcile
  [ "$status" -eq 1 ]
  [[ "$output" =~ "ERROR: signal-ingest refused to generate image tag" ]]
  [[ "$output" =~ "--auto-commit" ]]
  ! grep -q "rollout restart" "$CALL_LOG"
}

# ─── Additional workload option checks ───────────────────────────────────────

@test "workload option accepts signal-ingest alias" {
  run "$script" -w signal-ingest --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ "- signal-ingest (Signal Fusion Ingest Service)" ]]
}

@test "unknown workload option exits with error" {
  run "$script" -w invalid-workload-name
  [ "$status" -eq 1 ]
  [[ "$output" =~ "ERROR: Unknown workload 'invalid-workload-name'." ]]
}
