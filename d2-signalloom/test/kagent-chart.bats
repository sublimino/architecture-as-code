#!/usr/bin/env bats
# d2-signalloom/test/kagent-chart.bats — the upstream kagent 0.9.9 chart install
#
# These are static tests: they render the chart and read scripts/kagent-infra.sh
# and scripts/kagent-images.txt. Nothing here touches a cluster.
#
# ─── What they are actually defending ──────────────────────────────────────
#
# The failure this whole change fixes was not a crash. Four stub manifests
# impersonated a control plane — a python:3.12-alpine "controller" whose
# readiness probe was `echo ready`, a "tool server" that returned one hardcoded
# literal to every POST — and every check in the repo reported the control
# plane healthy while eight Agent CRs sat at `status: null`. A test that only
# asks "did it come up" cannot tell those two worlds apart.
#
# So the assertions below are about IDENTITY and ABSENCE, not liveness:
# which image, which key, which component is NOT there.
#
# The second thing they defend is subtler. Helm silently ignores a values key
# it does not recognise. The previous values.yaml carried four dead keys and
# missed two bundled agents, and rendered three Agent CRs on a cluster the file
# claimed ran none — with no warning from anything. Every test here that names
# a values key asserts against the RENDER, never against the file, because
# reading the file back only proves the file says what it says.
#
# Negative assertions are collected into a variable and tested with `[ -z ]`
# rather than written `! grep ...`. A bare `!`-negated command is exempt from
# errexit inside a bats @test and can never fail the test.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  KAGENT_DIR="${REPO_ROOT}/d2-signalloom/infra/kagent"
  CHART="oci://ghcr.io/kagent-dev/kagent/helm/kagent"
  CHART_VERSION="0.9.9"
}

render() {
  # $1: "base" or "observability"
  local args=(-f "${KAGENT_DIR}/values.yaml")
  if [ "${1:-base}" = "observability" ]; then
    args+=(-f "${KAGENT_DIR}/values-observability.yaml")
  fi
  helm template kagent "$CHART" --version "$CHART_VERSION" \
    --namespace kagent "${args[@]}"
}

# The chart quotes SOME image references and not others — `image: "cr.kagent.dev/…"`
# for the controller, UI, tools, grafana-mcp and querydoc, bare `image: docker.io/…`
# for PostgreSQL and kmcp. A grep for the quoted form silently misses two images
# and a grep for the bare form silently misses five, in both cases reading as
# "that image is not deployed". Normalise once here rather than guessing per call.
render_images() {
  render "${1:-base}" | sed -n 's/^[[:space:]]*image:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p'
}

@test "kagent-chart: base values render the chart cleanly" {
  run render base
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "kagent-chart: observability values render the chart cleanly" {
  run render observability
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ─── The regression signature: the stub images must never come back ────────

@test "kagent-chart: the control plane runs upstream images, not python/nginx stubs" {
  images="$(render_images base)"
  # Positive: the real controller and UI, pinned.
  echo "$images" | grep -qxF 'cr.kagent.dev/kagent-dev/kagent/controller:0.9.9'
  echo "$images" | grep -qxF 'cr.kagent.dev/kagent-dev/kagent/ui:0.9.9'
  echo "$images" | grep -qxF 'ghcr.io/kagent-dev/kagent/tools:0.2.1'

  # Negative: the three stub images, by name. Collected, not `! grep`.
  stubs="$(echo "$images" | grep -E '^(python|nginx):' || true)"
  [ -z "$stubs" ]
}

@test "kagent-chart: no manifest in the repo still deploys a stub kagent workload" {
  # The stub manifests are deleted; this fails if one is reintroduced anywhere
  # under the kagent infra tree, which is the only place they lived.
  offenders="$(grep -rlE 'python:3\.12-alpine|nginx:1\.27-alpine' "${KAGENT_DIR}" 2>/dev/null || true)"
  [ -z "$offenders" ]
}

@test "kagent-chart: the hand-written CRD manifest is gone and the chart supersedes it" {
  [ ! -f "${KAGENT_DIR}/crds/kagent-crds.yaml" ]
  # Rendered with the values the install actually uses, not the chart defaults.
  # The two differ on exactly one CRD and that difference is the whole point of
  # values-crds.yaml, so a test against the defaults would assert the opposite
  # of what gets installed.
  crds="$(helm template kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
    --version "$CHART_VERSION" --namespace kagent -f "${KAGENT_DIR}/values-crds.yaml")"
  echo "$crds" | grep -q 'name: agents.kagent.dev'
  echo "$crds" | grep -q 'name: modelconfigs.kagent.dev'
  echo "$crds" | grep -q 'name: remotemcpservers.kagent.dev'
  echo "$crds" | grep -q 'name: toolservers.kagent.dev'
}

@test "kagent-chart: kmcp is off, so the install cannot clobber mcpservers.kagent.dev" {
  # Installing the real MCPServer CRD requires deleting the hand-written one,
  # which cascades to five MCPServer CRs another workstream owns and which
  # cannot survive the real v1alpha1 schema. Both halves are asserted: the CRD
  # must not be rendered, and the controller must not be deployed.
  crds="$(helm template kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
    --version "$CHART_VERSION" --namespace kagent -f "${KAGENT_DIR}/values-crds.yaml")"
  mcp="$(echo "$crds" | grep -E '^  name: mcpservers.kagent.dev$' || true)"
  [ -z "$mcp" ]

  controller="$(render_images base | grep -E '^ghcr.io/kagent-dev/kmcp/' || true)"
  [ -z "$controller" ]

  # And the script must actually pass that values file, or none of the above
  # describes the install.
  grep -q 'VALUES_CRDS' "${REPO_ROOT}/scripts/kagent-infra.sh"
  grep -q -- '-f "${VALUES_CRDS}"' "${REPO_ROOT}/scripts/kagent-infra.sh"
}

@test "kagent-chart: the migration adopts CRDs rather than recreating them" {
  # agents.kagent.dev and modelconfigs.kagent.dev hold Signal Loom's eight
  # Agent CRs and its ModelConfig. Deleting them to let Helm recreate them
  # would destroy the objects this change exists to get reconciled.
  s="${REPO_ROOT}/scripts/kagent-infra.sh"
  grep -q 'adopt_crd agents.kagent.dev kagent-crds' "$s"
  grep -q 'adopt_crd modelconfigs.kagent.dev kagent-crds' "$s"
  # No unconditional CRD deletion anywhere in the script.
  deletes="$(grep -E 'kubectl delete crd' "$s" || true)"
  [ -z "$deletes" ]
}

# ─── Values keys must be live, proven against the render ───────────────────

@test "kagent-chart: the anthropic secret name reaches the generated ModelConfig" {
  # apiKeySecretName (the old spelling) renders NOTHING — the template only
  # branches on apiKeySecretRef. This test is the difference between the two.
  rendered="$(render base)"
  echo "$rendered" | grep -q 'apiKeySecret: kagent-anthropic-key'
  echo "$rendered" | grep -q 'provider: "Anthropic"'
}

@test "kagent-chart: the tool server gets a read-only ClusterRole, not cluster-admin" {
  rendered="$(render base)"
  echo "$rendered" | grep -q 'name: kagent-tools-read-role'
  admin="$(echo "$rendered" | grep -c 'kagent-tools-cluster-admin-role' || true)"
  [ "$admin" -eq 0 ]
}

@test "kagent-chart: no bundled kagent sample agent is deployed by the base values" {
  rendered="$(render base)"
  # Every bundled agent renders as an Agent CR. Signal Loom supplies its own
  # eight in fe-signalloom-agents; the chart's samples must all be off.
  agents="$(echo "$rendered" | grep -E '^  name: (k8s|kgateway|istio|promql|observability|argo-rollouts|helm|cilium-policy|cilium-manager|cilium-debug)-agent$' || true)"
  [ -z "$agents" ]
}

# ─── ENABLE_OBSERVABILITY gating ───────────────────────────────────────────

@test "kagent-chart: base values deploy no grafana-mcp, querydoc or observability-agent" {
  found="$(render_images base | grep -E '^(docker.io/)?mcp/grafana|^ghcr.io/kagent-dev/doc2vec' || true)"
  [ -z "$found" ]
  obs="$(render base | grep -E '^  name: observability-agent$' || true)"
  [ -z "$obs" ]
}

@test "kagent-chart: observability values deploy all three observability components" {
  images="$(render_images observability)"
  echo "$images" | grep -qxF 'docker.io/mcp/grafana:latest'
  echo "$images" | grep -qxF 'ghcr.io/kagent-dev/doc2vec/mcp:1.1.14'
  # The bare `mcp/grafana:latest` the chart defaults to must NOT survive: it is
  # unresolvable by scripts/lib/image-identity.sh and fails the preload.
  bare="$(echo "$images" | grep -x 'mcp/grafana:latest' || true)"
  [ -z "$bare" ]
  render observability | grep -qE '^  name: observability-agent$'
}

@test "kagent-chart: the image list splits on the same boundary as the values files" {
  images="${REPO_ROOT}/scripts/kagent-images.txt"
  [ -f "$images" ]
  grep -q '^# --- OBSERVABILITY ---$' "$images"

  # Above the marker: every always-on image, including the agent image the
  # chart never renders but the controller needs to materialise an Agent CR.
  always="$(sed '/^# --- OBSERVABILITY ---$/,$d' "$images")"
  echo "$always" | grep -q '^cr.kagent.dev/kagent-dev/kagent/controller:0.9.9$'
  echo "$always" | grep -q '^cr.kagent.dev/kagent-dev/kagent/ui:0.9.9$'
  echo "$always" | grep -q '^ghcr.io/kagent-dev/kagent/app:0.9.9$'
  echo "$always" | grep -q '^ghcr.io/kagent-dev/kagent/golang-adk:0.9.9$'
  echo "$always" | grep -q '^ghcr.io/kagent-dev/kagent/tools:0.2.1$'
  echo "$always" | grep -q '^docker.io/library/postgres:18.3-alpine$'

  # kmcp is disabled, so its controller image must NOT be preloaded. If this
  # ever fails it means kmcp came back on without the image list following it.
  kmcp="$(echo "$always" | grep -E '^ghcr.io/kagent-dev/kmcp/' || true)"
  [ -z "$kmcp" ]

  # The two observability images must NOT be above the marker, or
  # ENABLE_OBSERVABILITY=false would still pay to load them.
  leaked="$(echo "$always" | grep -E '^(docker.io/)?mcp/grafana|^ghcr.io/kagent-dev/doc2vec' || true)"
  [ -z "$leaked" ]

  below="$(sed -n '/^# --- OBSERVABILITY ---$/,$p' "$images")"
  echo "$below" | grep -q '^docker.io/mcp/grafana:latest$'
  echo "$below" | grep -q '^ghcr.io/kagent-dev/doc2vec/mcp:1.1.14$'
}

@test "kagent-chart: every always-on image in the list appears in the base render" {
  # The reverse direction of the test above: the list must not drift ahead of
  # the chart. kagent/app is excluded because the controller supplies it at
  # runtime and it deliberately does not appear in any template.
  images="$(render_images base)"
  missing=""
  while IFS= read -r img; do
    case "$img" in ''|'#'*) continue ;; esac
    # The two agent runtime images are supplied by the controller at
    # agent-compile time and appear in no chart template, by design.
    case "$img" in
      ghcr.io/kagent-dev/kagent/app:*|ghcr.io/kagent-dev/kagent/golang-adk:*) continue ;;
    esac
    echo "$images" | grep -qxF "$img" || missing="${missing} ${img}"
  done < <(sed '/^# --- OBSERVABILITY ---$/,$d' "${REPO_ROOT}/scripts/kagent-images.txt" \
            | grep -vE '^[[:space:]]*(#|$)')
  [ -z "$missing" ]
}

# ─── The install script ────────────────────────────────────────────────────

@test "kagent-chart: kagent-infra.sh installs by Helm, pinned, and no longer applies the stub overlay" {
  s="${REPO_ROOT}/scripts/kagent-infra.sh"
  grep -q 'oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds' "$s"
  grep -q 'oci://ghcr.io/kagent-dev/kagent/helm/kagent' "$s"
  grep -q 'CHART_VERSION="${KAGENT_CHART_VERSION:-0.9.9}"' "$s"
  # upgrade --install, not install: this is what makes `up` twice safe.
  grep -q 'upgrade --install' "$s"
  # The stub overlay path must be gone.
  old="$(grep -F 'infra/kagent/local' "$s" || true)"
  [ -z "$old" ]
}

@test "kagent-chart: down does not delete CRDs by default" {
  # Deleting kagent's CRDs cascades to every Agent CR in the cluster, including
  # the eight in fe-signalloom-agents that this script does not own. The old
  # `kubectl delete -k .../crds` did that on every `down`.
  s="${REPO_ROOT}/scripts/kagent-infra.sh"
  grep -q 'KAGENT_DOWN_REMOVE_CRDS' "$s"
  unconditional="$(grep -E '^[[:space:]]*(kubectl delete -k .*crds|"\$HELM_BIN" uninstall kagent-crds)' "$s" || true)"
  # The only uninstall of the crds release must sit inside the opt-in branch,
  # which this grep proves by requiring it to be indented deeper than the case arm.
  echo "$unconditional" | grep -qE '^      "\$HELM_BIN" uninstall kagent-crds' || [ -z "$unconditional" ]
}

@test "kagent-chart: the namespace overlay still carries Signal Loom governance labels" {
  # helm --create-namespace would produce a bare namespace. The overlay is
  # applied first precisely so it does not.
  out="$(kubectl kustomize "${KAGENT_DIR}/local")"
  echo "$out" | grep -q 'controlplane.io/governance: infrastructure'
  echo "$out" | grep -q 'app.kubernetes.io/part-of: signalloom'
}

@test "kagent-chart: network policies select pods the chart actually creates" {
  # A podSelector matching nothing is not an error, is not a warning, and
  # constrains no traffic. Both policies previously selected stub labels.
  policies="$(kubectl kustomize "${KAGENT_DIR}/local")"
  rendered="$(render base)"

  # The labels the policies select must appear on a chart pod template.
  echo "$rendered" | grep -q 'app.kubernetes.io/component: database'
  echo "$rendered" | grep -q 'app.kubernetes.io/name: kagent-tools'

  # And the stub labels must be gone from the policies.
  stale="$(echo "$policies" | grep -E 'kagent-postgres$|kagent-tool-server$' || true)"
  [ -z "$stale" ]

  # The tool server port must be the chart's 8084, not the stub's 8080.
  echo "$policies" | grep -q 'port: 8084'
}

@test "kagent-chart: the agent runtime registry is overridden to ghcr in the rendered ConfigMap" {
  # cr.kagent.dev does not carry golang-adk, which is the runtime for every
  # `runtime: go` agent — i.e. all eight of Signal Loom's. Asserted against the
  # rendered ConfigMap rather than the values file, because
  # controller-configmap.yaml derives IMAGE_REGISTRY through a `default` chain
  # and only the render proves which end of it won.
  rendered="$(render base)"
  echo "$rendered" | grep -q 'IMAGE_REGISTRY: "ghcr.io"'
  # Scoped, not global: the controller, UI and skills-init images must stay on
  # cr.kagent.dev, where they are published and working.
  echo "$rendered" | grep -q 'SKILLS_INIT_IMAGE_REGISTRY: "cr.kagent.dev"'
  echo "$(render_images base)" | grep -qxF 'cr.kagent.dev/kagent-dev/kagent/controller:0.9.9'
}
