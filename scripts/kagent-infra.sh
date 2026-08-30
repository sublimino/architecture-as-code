#!/usr/bin/env bash
# scripts/kagent-infra.sh — kagent 0.9.9 control-plane lifecycle (Demo 5)
#
# Installs the UPSTREAM kagent Helm charts:
#
#   oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds  --version 0.9.9
#   oci://ghcr.io/kagent-dev/kagent/helm/kagent       --version 0.9.9
#
# ─── What this replaced, and why it mattered ───────────────────────────────
#
# Until this rewrite, "the kagent control plane" in this repo was four
# hand-written manifests that impersonated one:
#
#   base/controller.yaml   python:3.12-alpine running an inline script. Its
#                          readiness probe was `echo ready`. It watched
#                          nothing and reconciled nothing.
#   base/tool-server.yaml  python:3.12-alpine running http.server. Every POST
#                          returned one hardcoded literal — POSTing the tool
#                          name `k8s_get_resources` and the tool name
#                          `totally_made_up_xyz` produced byte-identical
#                          output. It never spoke to the API server.
#   base/ui.yaml           nginx serving a static HTML page listing three
#                          agents.
#   crds/kagent-crds.yaml  three hand-written CRDs.
#
# The visible consequence was that all eight Agent CRs in fe-signalloom-agents
# sat with `status: null` forever, with a "controller" pod Running beside them.
# The invisible one is worse: every check in the repo that asked "is kagent up"
# got a truthful yes.
#
# ─── Idempotence ───────────────────────────────────────────────────────────
#
# `up` is `helm upgrade --install` twice over, so running it repeatedly is a
# no-op convergence rather than a conflict. The namespace and NetworkPolicies
# are applied with `kubectl apply -k`, likewise idempotent. Image preload is
# skipped for anything already proven present on the node.
#
# ─── ENABLE_OBSERVABILITY ──────────────────────────────────────────────────
#
# false (the repo default, Makefile:55): controller, kagent-tools, UI, bundled
# PostgreSQL and kmcp. true: adds observability-agent, grafana-mcp and
# querydoc, by layering values-observability.yaml as a second -f. Threaded the
# same way scripts/push-local.sh and scripts/wait-reconciled.sh read it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/wait.sh
source "${REPO_ROOT}/scripts/lib/wait.sh"

KUBECONFIG_PATH="${KUBECONFIG:-${REPO_ROOT}/.kind/kubeconfig}"
if [ -f "${KUBECONFIG_PATH}" ]; then
  export KUBECONFIG="${KUBECONFIG_PATH}"
fi

NS="kagent"
RELEASE="kagent"
# The release name is load-bearing, not cosmetic. templates/toolserver-kagent.yaml
# names the RemoteMCPServer `{{ include "kagent.fullname" . }}-tool-server`, which
# with no nameOverride is `<release>-tool-server`. Signal Loom's eight Agent CRs
# reference `kagent-tool-server` by name, so the release must stay `kagent`.
CRDS_CHART="oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds"
CHART="oci://ghcr.io/kagent-dev/kagent/helm/kagent"
CHART_VERSION="${KAGENT_CHART_VERSION:-0.9.9}"

VALUES="${REPO_ROOT}/d2-signalloom/infra/kagent/values.yaml"
VALUES_OBS="${REPO_ROOT}/d2-signalloom/infra/kagent/values-observability.yaml"
VALUES_CRDS="${REPO_ROOT}/d2-signalloom/infra/kagent/values-crds.yaml"
IMAGES_FILE="${REPO_ROOT}/scripts/kagent-images.txt"

ENABLE_OBSERVABILITY="${ENABLE_OBSERVABILITY:-false}"
HELM_BIN="${HELM_BIN:-helm}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
# Same defaults and same env-var names as scripts/kind-load-verified.sh, so the
# two agree about which node they are talking to rather than each inventing one.
CLUSTER_NAME="${CLUSTER_NAME:-osramp}"
NODE="${KIND_LOAD_NODE:-${CLUSTER_NAME}-control-plane}"
# Set to any non-empty value to install without touching host Docker or the
# kind node — for a cluster whose nodes can pull these registries directly.
KAGENT_SKIP_IMAGE_PRELOAD="${KAGENT_SKIP_IMAGE_PRELOAD:-}"

ACTION="${1:-up}"

log()  { printf '\033[1;36m[kagent]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[kagent] ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[kagent] !\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[kagent] FAILED:\033[0m %s\n' "$*" >&2; exit 1; }

# Values files for the current gating, in -f order. Later files win.
helm_values_args() {
  printf '%s\n' "-f" "${VALUES}"
  if [ "${ENABLE_OBSERVABILITY}" = "true" ]; then
    printf '%s\n' "-f" "${VALUES_OBS}"
  fi
}

# Images from scripts/kagent-images.txt for the current gating.
#
# The file is split by a `# --- OBSERVABILITY ---` marker: entries above it are
# always needed, entries below only when the overlay is applied. Parsed with awk
# rather than two files because the always-on set and the observability set have
# to stay in step with the two values files, and one list is easier to keep
# honest than two.
kagent_images() {
  awk -v want_obs="${ENABLE_OBSERVABILITY}" '
    /^# --- OBSERVABILITY ---$/ { obs = 1; next }
    /^[[:space:]]*#/           { next }
    /^[[:space:]]*$/           { next }
    { sub(/[[:space:]]*#.*$/, "") }
    obs && want_obs != "true"  { next }
    NF                         { print $1 }
  ' "${IMAGES_FILE}"
}

# Pull to host Docker, then hand the set to kind-load-verified.sh.
#
# Two steps, because they answer different questions and both have bitten this
# repo. The pull is needed because cr.kagent.dev is NOT one of the five hosts
# scripts/registry-cache.sh mirrors, so nothing on the node caches it. The
# verified load is needed because `kind load` can exit 0 having transferred
# nothing — see the header of scripts/kind-load-verified.sh, which is the only
# check in this repo that proves an image is on the node by identity rather
# than by tag.
preload_images() {
  if [ -n "${KAGENT_SKIP_IMAGE_PRELOAD}" ]; then
    warn "KAGENT_SKIP_IMAGE_PRELOAD set — trusting the node to pull these itself"
    return 0
  fi

  local images=() image
  while IFS= read -r image; do
    [ -n "$image" ] && images+=("$image")
  done < <(kagent_images)

  [ "${#images[@]}" -gt 0 ] || fail "no images parsed from ${IMAGES_FILE}"

  log "ensuring ${#images[@]} kagent image(s) in host Docker (ENABLE_OBSERVABILITY=${ENABLE_OBSERVABILITY})"
  for image in "${images[@]}"; do
    if "$DOCKER_BIN" image inspect "$image" >/dev/null 2>&1; then
      log "  already local  $image"
    else
      log "  pulling        $image"
      "$DOCKER_BIN" pull -q "$image" >/dev/null \
        || fail "could not pull ${image}. cr.kagent.dev and ghcr.io must be reachable from this host, or set KAGENT_SKIP_IMAGE_PRELOAD=1 and let the node pull."
    fi
  done

  log "loading them onto the kind node and proving they arrived"
  "${REPO_ROOT}/scripts/kind-load-verified.sh" "${images[@]}"
}

# ─── Migrating a cluster that still carries the stub control plane ─────────
#
# On a fresh cluster this is a no-op and costs four `kubectl get`s. On a
# cluster that ran the old manifests it is the difference between an install
# and an error, because the stubs and the chart share four names —
# kagent-controller, kagent-ui (Deployment, Service, ServiceAccount) — and Helm
# will not adopt a resource it did not create:
#
#   Unable to continue with install: Deployment "kagent-controller" in
#   namespace "kagent" exists and cannot be imported into the current release
#
# So the rule applied here is narrow and stated rather than clever: delete a
# resource the chart is about to create ONLY when it exists and carries no
# Helm ownership annotation. A Helm-owned one is a previous run of this script
# and must be upgraded, not deleted.
#
# The CRDs are the opposite case. agents.kagent.dev and modelconfigs.kagent.dev
# hold Signal Loom's eight Agent CRs and its ModelConfig, so deleting them to
# let Helm recreate them would destroy the very objects this change exists to
# get reconciled. They are ADOPTED instead — labelled and annotated into the
# kagent-crds release so Helm upgrades the schema in place. Both already store
# v1alpha2, which the upstream CRD also serves and stores, so the schema
# replacement is an upgrade rather than a version migration.
#
# mcpservers.kagent.dev is neither deleted nor adopted; see the KMCP section of
# values.yaml for why the chart does not manage it at all.
HELM_OWNER_JSONPATH='{.metadata.annotations.meta\.helm\.sh/release-name}'

drop_unowned() {
  local kind="$1" name="$2" owner
  kubectl get "$kind" "$name" -n "${NS}" >/dev/null 2>&1 || return 0
  owner="$(kubectl get "$kind" "$name" -n "${NS}" -o jsonpath="${HELM_OWNER_JSONPATH}" 2>/dev/null || true)"
  if [ -n "$owner" ]; then
    log "  keeping ${kind}/${name} (already owned by Helm release '${owner}')"
    return 0
  fi
  warn "  deleting stub ${kind}/${name} — exists, unowned, and the chart creates this name"
  kubectl delete "$kind" "$name" -n "${NS}" --timeout=60s >/dev/null
}

adopt_crd() {
  local name="$1" release="$2" owner
  kubectl get crd "$name" >/dev/null 2>&1 || return 0
  owner="$(kubectl get crd "$name" -o jsonpath="${HELM_OWNER_JSONPATH}" 2>/dev/null || true)"
  if [ "$owner" = "$release" ]; then
    log "  ${name} already annotated for '${release}'"
  else
    log "  adopting ${name} into the '${release}' release (preserves every CR it holds)"
    kubectl label   crd "$name" 'app.kubernetes.io/managed-by=Helm' --overwrite >/dev/null
    kubectl annotate crd "$name" "meta.helm.sh/release-name=${release}" \
                                  "meta.helm.sh/release-namespace=${NS}" --overwrite >/dev/null
  fi

  # Deliberately NOT inside the else branch above. Annotating and retiring the
  # field manager are two independent halves of one adoption, and an earlier
  # revision returned early once the annotations were on — so a run that got
  # halfway through left a CRD that LOOKED adopted and still failed the apply,
  # with the second half unreachable on every subsequent run. The patch is a
  # no-op when the manager is absent, so running it always costs one get.
  # The Helm annotations alone are not enough, and the error you get if you stop
  # here names neither Helm nor ownership:
  #
  #   conflict occurred while applying object /agents.kagent.dev ...
  #   Apply failed with 1 conflict: conflict with "kubectl-client-side-apply"
  #   using apiextensions.k8s.io/v1: .spec.versions
  #
  # Helm 4 applies server-side. The hand-written CRDs were created by
  # `kubectl apply` in its client-side mode, which registered a field manager
  # called kubectl-client-side-apply owning .spec.versions — precisely the
  # field the real CRD has to change (it adds v1alpha1 alongside the existing
  # v1alpha2). Server-side apply refuses to take a field another manager owns.
  #
  # Removing the `last-applied-configuration` annotation does NOT retire that
  # manager — measured, not assumed: the annotation went away and the identical
  # conflict came back on the next run, because the managedFields entry is
  # independent of the annotation that produced it. The entry itself has to go.
  #
  # Done surgically rather than by arming `--force-conflicts` on the release.
  # This is a one-time migration of two specific objects; the flag would sit
  # permanently on every future upgrade and force through any conflict with any
  # manager, which is a much larger and much quieter permission.
  #
  # NOTE `--show-managed-fields` is required: kubectl strips managedFields from
  # `get -o json` by default, so without it this reads as "there are no field
  # managers" and the patch below silently never runs.
  local idx
  idx="$(kubectl get crd "$name" --show-managed-fields -o json 2>/dev/null | python3 -c '
import json,sys
d = json.load(sys.stdin)
for i, m in enumerate(d["metadata"].get("managedFields", [])):
    if m["manager"] == "kubectl-client-side-apply":
        print(i); break
' || true)"
  if [ -n "$idx" ]; then
    log "  retiring the kubectl-client-side-apply field manager on ${name} (owns .spec.versions)"
    kubectl patch crd "$name" --type=json \
      -p "[{\"op\":\"remove\",\"path\":\"/metadata/managedFields/${idx}\"}]" >/dev/null
  fi
}

migrate_from_stubs() {
  kubectl get namespace "${NS}" >/dev/null 2>&1 || return 0

  log "checking for the hand-rolled stub control plane"
  local n
  for n in kagent-controller kagent-ui kagent-tool-server kagent-postgres; do
    drop_unowned deployment "$n"
    drop_unowned service "$n"
    drop_unowned serviceaccount "$n"
  done
  drop_unowned configmap kagent-ui-nginx-config

  # Cluster-scoped grants the stubs created. No name collision with the chart
  # (which uses kagent-getter-role / kagent-writer-role / kagent-tools-*), so
  # nothing forces their removal — but leaving them behind leaves ClusterRoles
  # bound to ServiceAccounts that no longer exist, which is a live grant
  # waiting for the next object to reuse the name.
  for n in kagent-controller-role kagent-reader-role; do
    if kubectl get clusterrole "$n" >/dev/null 2>&1 \
       && [ -z "$(kubectl get clusterrole "$n" -o jsonpath="${HELM_OWNER_JSONPATH}" 2>/dev/null || true)" ]; then
      warn "  deleting orphan stub ClusterRole/${n}"
      kubectl delete clusterrole "$n" --timeout=60s >/dev/null
    fi
  done
  for n in kagent-controller-binding kagent-reader-binding; do
    if kubectl get clusterrolebinding "$n" >/dev/null 2>&1 \
       && [ -z "$(kubectl get clusterrolebinding "$n" -o jsonpath="${HELM_OWNER_JSONPATH}" 2>/dev/null || true)" ]; then
      warn "  deleting orphan stub ClusterRoleBinding/${n}"
      kubectl delete clusterrolebinding "$n" --timeout=60s >/dev/null
    fi
  done

  log "adopting pre-existing kagent CRDs rather than recreating them"
  adopt_crd agents.kagent.dev kagent-crds
  adopt_crd modelconfigs.kagent.dev kagent-crds
}

case "${ACTION}" in
  up)
    [ -f "${VALUES}" ] || fail "missing values file ${VALUES}"
    if [ "${ENABLE_OBSERVABILITY}" = "true" ] && [ ! -f "${VALUES_OBS}" ]; then
      fail "ENABLE_OBSERVABILITY=true but ${VALUES_OBS} is missing"
    fi

    preload_images

    # Namespace and NetworkPolicies first, so the namespace carries Signal
    # Loom's governance labels rather than the bare one helm --create-namespace
    # would make, and so the policies exist before the pods they constrain.
    log "applying Signal Loom namespace and network posture"
    kubectl apply -k "${REPO_ROOT}/d2-signalloom/infra/kagent/base"
    wait_k8s_exists namespace "${NS}" 60

    migrate_from_stubs

    log "installing ${CRDS_CHART} ${CHART_VERSION}"
    "$HELM_BIN" upgrade --install kagent-crds "${CRDS_CHART}" \
      --version "${CHART_VERSION}" \
      --namespace "${NS}" \
      -f "${VALUES_CRDS}" \
      --wait --timeout 5m

    # Named individually rather than counted: a CRD chart that installs some of
    # its CRDs is a partial failure that a count would report as success once
    # the count happened to match.
    wait_k8s_exists crd agents.kagent.dev 60
    wait_k8s_exists crd modelconfigs.kagent.dev 60
    wait_k8s_exists crd remotemcpservers.kagent.dev 60
    wait_k8s_exists crd toolservers.kagent.dev 60

    log "installing ${CHART} ${CHART_VERSION} (ENABLE_OBSERVABILITY=${ENABLE_OBSERVABILITY})"
    mapfile -t _values_args < <(helm_values_args)
    # NOT --wait, deliberately, and the explicit wait_rollout calls below are
    # the replacement rather than an omission.
    #
    # Helm 4's --wait includes custom resources, and it waits for an Agent CR to
    # report Ready. An Agent only becomes Ready once the controller has compiled
    # it AND its agent pod is up, which depends on a working model credential
    # supplied by a different workstream from OpenBao. So --wait ties the exit
    # status of an infrastructure install to whether an LLM API key is valid and
    # to whether an unrelated agent's tools resolve, and reports the failure as
    #
    #   Error: UPGRADE FAILED: resource Agent/kagent/observability-agent not
    #   ready. status: InProgress ... context deadline exceeded
    #
    # after burning the full 10-minute budget, having successfully deployed
    # every workload. Waiting on the Deployments is the check that actually
    # corresponds to "the control plane is up", and it names which one failed.
    #
    # --wait is KEPT on the CRDs release above: CRDs establish in seconds and
    # have no such dependency.
    "$HELM_BIN" upgrade --install "${RELEASE}" "${CHART}" \
      --version "${CHART_VERSION}" \
      --namespace "${NS}" \
      "${_values_args[@]}" \
      --timeout 10m

    log "waiting for the control plane"
    wait_rollout "${RELEASE}-postgresql" -n "${NS}" 300
    wait_rollout "${RELEASE}-controller" -n "${NS}" 300
    wait_rollout "${RELEASE}-tools" -n "${NS}" 300
    wait_rollout "${RELEASE}-ui" -n "${NS}" 300

    if [ "${ENABLE_OBSERVABILITY}" = "true" ]; then
      wait_rollout "${RELEASE}-grafana-mcp" -n "${NS}" 300
      wait_rollout "${RELEASE}-querydoc" -n "${NS}" 300
    fi

    ok "kagent ${CHART_VERSION} control plane is up"
    kubectl get pods -n "${NS}" -o wide
    ;;

  down)
    log "uninstalling the kagent release"
    "$HELM_BIN" uninstall "${RELEASE}" --namespace "${NS}" --wait --timeout 5m 2>/dev/null || true

    log "removing namespace '${NS}'"
    if kubectl get namespace "${NS}" >/dev/null 2>&1; then
      kubectl delete namespace "${NS}" --timeout=120s || true
    fi

    # CRDs last and deliberately, because deleting them deletes every Agent,
    # ModelConfig and RemoteMCPServer in the cluster — including Signal Loom's
    # eight in fe-signalloom-agents, which this script does not own. The old
    # `kubectl delete -k .../crds` did exactly that silently.
    if [ "${KAGENT_DOWN_REMOVE_CRDS:-false}" = "true" ]; then
      warn "KAGENT_DOWN_REMOVE_CRDS=true — this also deletes every Agent CR in every namespace"
      "$HELM_BIN" uninstall kagent-crds --namespace "${NS}" --wait --timeout 5m 2>/dev/null || true
    else
      log "leaving CRDs installed (set KAGENT_DOWN_REMOVE_CRDS=true to remove them; it cascades to all Agent CRs)"
    fi

    ok "kagent control plane removed"
    ;;

  status)
    echo "=== kagent control plane ==="
    echo "namespace:             ${NS}"
    echo "chart version:         ${CHART_VERSION}"
    echo "ENABLE_OBSERVABILITY:  ${ENABLE_OBSERVABILITY}"
    echo ""
    "$HELM_BIN" list --namespace "${NS}" || true
    echo ""
    if kubectl get namespace "${NS}" >/dev/null 2>&1; then
      kubectl get pods -n "${NS}" \
        -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[*].image,READY:.status.containerStatuses[*].ready
      echo ""
      echo "=== CRDs ==="
      kubectl get crd -o name | grep -E 'kagent\.dev' || true
    else
      echo "namespace '${NS}' does not exist (not deployed)."
    fi
    ;;

  *)
    # `Usage: kagent-infra.sh ...` — basename, not $0. The path form is
    # unstable (it differs between `./scripts/kagent-infra.sh`, an absolute
    # invocation from a Make recipe, and a bats temp dir), so anything matching
    # on it matches inconsistently.
    #
    # Exit 2, not 1, and it is a contract rather than a preference: 2 is
    # "wrong usage" as distinct from 1 "the thing you asked for failed". A
    # caller that cannot tell those apart retries an unretryable typo. This is
    # the one assertion the original test/kagent-infra.bats made that described
    # this script rather than the stub architecture it was written against, so
    # it is honoured rather than rewritten.
    echo "Usage: $(basename "$0") [up|down|status]" >&2
    exit 2
    ;;
esac
