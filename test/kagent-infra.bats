#!/usr/bin/env bats
# test/kagent-infra.bats — lifecycle contract for scripts/kagent-infra.sh
#
# ─── Why this file was rewritten rather than satisfied ─────────────────────
#
# The previous version had been permanently red and excluded from the runner,
# so `make demo-kagent-test` was green while this was failing. It was put back
# into the runner by the kagent-tests-docs workstream without either side being
# changed, which is the correct order: decide deliberately, do not re-hide it.
#
# The decision is to rewrite, because three of its four tests asserted the STUB
# ARCHITECTURE, not merely an interface the script happened to lack:
#
#   KAGENT_INFRA_MANIFEST_DIR + `apply -k $manifests`
#       the whole control plane came from one kustomize directory. It now comes
#       from two pinned upstream Helm charts. There is no manifest directory to
#       point at; the only kustomize left is the namespace and NetworkPolicies.
#   rollout status deploy/kagent-postgres, deploy/kagent-tool-server
#       stub workload names. The chart's are kagent-postgresql and kagent-tools.
#       An assertion on the old names can only be satisfied by re-creating the
#       stubs.
#   `delete -k $manifests` on down
#       that path deleted the CRDs, which cascades to every Agent CR in the
#       cluster including the eight in fe-signalloom-agents that this script
#       does not own. Asserting it would be asserting a data-loss bug.
#
# Growing the script to honour those would mean re-adding the architecture the
# change removed. So the interface moves and the tests follow it.
#
# The fourth test — unknown command exits 2 with a usage banner — was
# architecture-neutral, the script already satisfies it, and it is kept verbatim
# in spirit below.
#
# ─── Tier 1: no cluster, no network ────────────────────────────────────────
#
# kubectl, helm and docker are all injected as fakes. That is possible only
# because the script takes HELM_BIN and DOCKER_BIN from the environment and
# resolves kubectl through PATH; if a future change hardcodes any of them, these
# tests are the thing that notices.
#
# Negative assertions collect to a variable and test with `[ -z ]`. A bare
# `! grep` inside a @test is exempt from errexit and can never fail.

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  bin="$BATS_TEST_TMPDIR/bin"
  log="$BATS_TEST_TMPDIR/commands.log"
  mkdir -p "$bin"

  # kubectl: logs, succeeds, prints nothing. Printing nothing matters — the
  # script reads the Helm ownership annotation via jsonpath, and an empty
  # result is what "not Helm-owned" looks like, which is the arm that runs on a
  # cluster still carrying the stubs.
  cat >"$bin/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$COMMAND_LOG"
# --show-managed-fields is the field-manager probe; hand it valid empty JSON so
# the python filter that reads it does not explode.
case "$*" in
  *--show-managed-fields*) printf '{"metadata":{"managedFields":[]}}' ;;
esac
exit 0
SCRIPT

  cat >"$bin/helm" <<'SCRIPT'
#!/usr/bin/env bash
printf 'helm %s\n' "$*" >>"$COMMAND_LOG"
exit 0
SCRIPT

  cat >"$bin/docker" <<'SCRIPT'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$COMMAND_LOG"
exit 0
SCRIPT

  chmod +x "$bin/kubectl" "$bin/helm" "$bin/docker"
  : >"$log"
}

# run_lifecycle [VAR=VAL ...] -- <action>
#
# Everything before `--` is extra environment, everything after is the script's
# own argv. `env` stops treating words as assignments at the first non-assignment,
# so the script path has to come after the assignments and before the action —
# writing `env ... -- up script.sh` makes `env` exec `up`, which is exit 127 and
# reads as "the script is missing" rather than "the test harness is wrong".
run_lifecycle() {
  local extra=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do extra+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  run env PATH="$bin:$PATH" COMMAND_LOG="$log" WAIT_QUIET=1 \
    KAGENT_SKIP_IMAGE_PRELOAD=1 \
    HELM_BIN="$bin/helm" DOCKER_BIN="$bin/docker" \
    "${extra[@]}" "$root/scripts/kagent-infra.sh" "$@"
}

# ─── up ────────────────────────────────────────────────────────────────────

@test "up installs both upstream charts, pinned, via upgrade --install" {
  run_lifecycle ENABLE_OBSERVABILITY=false -- up
  [ "$status" -eq 0 ]
  grep -Fq 'upgrade --install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds' "$log"
  grep -Fq 'upgrade --install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent' "$log"
  # Pinned, twice. An unpinned chart is a different install every day.
  [ "$(grep -c -- '--version 0.9.9' "$log")" -eq 2 ]
  # `upgrade --install` rather than `install` is what makes `up` twice safe.
  plain_install="$(grep -E 'helm install ' "$log" || true)"
  [ -z "$plain_install" ]
}

@test "up applies the namespace overlay before Helm, and only the namespace overlay" {
  run_lifecycle ENABLE_OBSERVABILITY=false -- up
  [ "$status" -eq 0 ]
  grep -Fq 'apply -k' "$log"
  grep -Fq 'infra/kagent/base' "$log"
  # The stub overlay applied the whole control plane through kustomize. If that
  # path ever comes back, the chart and the kustomize output fight over four
  # shared names.
  stub_overlay="$(grep -F 'infra/kagent/local' "$log" || true)"
  [ -z "$stub_overlay" ]
  # Ordering: kustomize must precede the first helm call, or the namespace does
  # not exist when the release lands in it.
  apply_line="$(grep -n 'apply -k' "$log" | head -1 | cut -d: -f1)"
  helm_line="$(grep -n '^helm ' "$log" | head -1 | cut -d: -f1)"
  [ "$apply_line" -lt "$helm_line" ]
}

@test "up waits on the chart's real workload names, not the stub names" {
  run_lifecycle ENABLE_OBSERVABILITY=false -- up
  [ "$status" -eq 0 ]
  for d in kagent-postgresql kagent-controller kagent-tools kagent-ui; do
    grep -Fq "rollout status deploy/$d" "$log"
  done
  # The stub names must never be waited on again — nothing creates them.
  stubs="$(grep -E 'rollout status deploy/(kagent-postgres|kagent-tool-server)$' "$log" || true)"
  [ -z "$stubs" ]
}

@test "up adopts the pre-existing CRDs instead of deleting them" {
  run_lifecycle ENABLE_OBSERVABILITY=false -- up
  [ "$status" -eq 0 ]
  grep -Fq 'annotate crd agents.kagent.dev meta.helm.sh/release-name=kagent-crds' "$log"
  grep -Fq 'annotate crd modelconfigs.kagent.dev meta.helm.sh/release-name=kagent-crds' "$log"
  # Deleting agents.kagent.dev cascades to all eight Agent CRs.
  crd_deletes="$(grep -E 'kubectl delete crd' "$log" || true)"
  [ -z "$crd_deletes" ]
}

# ─── ENABLE_OBSERVABILITY ──────────────────────────────────────────────────

@test "up layers the observability values file only when the flag is true" {
  run_lifecycle ENABLE_OBSERVABILITY=false -- up
  [ "$status" -eq 0 ]
  off="$(grep -F 'values-observability.yaml' "$log" || true)"
  [ -z "$off" ]

  : >"$log"
  run_lifecycle ENABLE_OBSERVABILITY=true -- up
  [ "$status" -eq 0 ]
  grep -Fq 'values-observability.yaml' "$log"
  # Layered on top of the base file, never instead of it.
  grep -Fq 'infra/kagent/values.yaml' "$log"
}

@test "up gives the CRDs release its own values file" {
  # kmcp.enabled=false lives there; without it the install replaces
  # mcpservers.kagent.dev and cascades to five MCPServer CRs it does not own.
  run_lifecycle ENABLE_OBSERVABILITY=false -- up
  [ "$status" -eq 0 ]
  grep -Fq 'values-crds.yaml' "$log"
}

@test "up waits on the observability deployments only when the flag is true" {
  run_lifecycle ENABLE_OBSERVABILITY=false -- up
  [ "$status" -eq 0 ]
  off="$(grep -E 'rollout status deploy/kagent-(grafana-mcp|querydoc)' "$log" || true)"
  [ -z "$off" ]

  : >"$log"
  run_lifecycle ENABLE_OBSERVABILITY=true -- up
  [ "$status" -eq 0 ]
  grep -Fq 'rollout status deploy/kagent-grafana-mcp' "$log"
  grep -Fq 'rollout status deploy/kagent-querydoc' "$log"
}

# ─── down ──────────────────────────────────────────────────────────────────

@test "down uninstalls the release but leaves CRDs alone by default" {
  run_lifecycle -- down
  [ "$status" -eq 0 ]
  grep -Fq 'uninstall kagent --namespace kagent' "$log"
  # The CRDs release must NOT be uninstalled: it owns agents.kagent.dev, and
  # removing it deletes every Agent CR in every namespace.
  crds_uninstall="$(grep -F 'uninstall kagent-crds' "$log" || true)"
  [ -z "$crds_uninstall" ]
  crd_deletes="$(grep -E 'kubectl delete crd|delete -k .*crds' "$log" || true)"
  [ -z "$crd_deletes" ]
}

@test "down removes CRDs only behind the explicit opt-in" {
  run_lifecycle KAGENT_DOWN_REMOVE_CRDS=true -- down
  [ "$status" -eq 0 ]
  grep -Fq 'uninstall kagent-crds' "$log"
}

# ─── status ────────────────────────────────────────────────────────────────

@test "status is read-only" {
  run_lifecycle -- status
  [ "$status" -eq 0 ]
  mutations="$(grep -E 'kubectl (apply|delete|create|patch|annotate|label|replace) ' "$log" || true)"
  [ -z "$mutations" ]
  helm_mutations="$(grep -E 'helm (upgrade|install|uninstall|rollback) ' "$log" || true)"
  [ -z "$helm_mutations" ]
}

# ─── usage ─────────────────────────────────────────────────────────────────
# Kept from the original suite. It was the one test that described the script
# rather than the stub architecture, and it still passes unchanged.

@test "unknown lifecycle command fails with usage" {
  run_lifecycle -- invalid
  [ "$status" -eq 2 ]
  [[ "$output" == *'Usage: kagent-infra.sh'* ]]
}

# ─── image preload boundary ────────────────────────────────────────────────

@test "the image preload is skippable, and skipping it touches neither docker nor the node" {
  run_lifecycle ENABLE_OBSERVABILITY=false -- up
  [ "$status" -eq 0 ]
  pulls="$(grep -E '^docker (pull|tag|exec)' "$log" || true)"
  [ -z "$pulls" ]
}

@test "the image list parses, splits on the observability marker, and is not empty" {
  # Exercises kagent_images() through the script's own awk rather than
  # reimplementing the parse here, which would only prove the copy agrees with
  # itself.
  images="$root/scripts/kagent-images.txt"
  [ -f "$images" ]
  always="$(awk '/^# --- OBSERVABILITY ---$/{exit} /^[[:space:]]*#/{next} /^[[:space:]]*$/{next} {sub(/[[:space:]]*#.*$/,""); if (NF) print $1}' "$images")"
  [ -n "$always" ]
  # Every entry must be a fully-qualified reference with a tag. A bare
  # `mcp/grafana:latest` cannot be canonicalised by scripts/lib/image-identity.sh
  # and fails the CRI-adopt step with a message that blames the loader.
  malformed="$(printf '%s\n' "$always" | grep -vE '^[a-z0-9.-]+\.[a-z]+/[^:]+:[^:]+$' || true)"
  [ -z "$malformed" ]
}
