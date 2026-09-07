#!/usr/bin/env bash
set -euo pipefail
# apps/fe-signalloom/base/netassert-signalloom.yaml is a committed copy of
# this directory's netassert-signalloom.yaml, needed because kustomize's
# default load restrictor refuses configMapGenerator `files:` sources outside
# the kustomization root (verified: a `../../../test/...` reference here
# fails `kubectl kustomize` with "is not in or below" even though the
# equivalent cross-directory reference already exists for
# infra/inf-signalloom/controllers/base's discovery-portal-bootstrap.sql
# generator). Same trade-off as check-bootstrap-drift.sh: commit the
# duplicate, catch staleness mechanically rather than by hoping nobody edits
# one copy and forgets the other.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
canonical="${NETASSERT_CONFIG:-$root/test/netassert-signalloom.yaml}"
deployed="${NETASSERT_DEPLOY_CONFIG:-$root/apps/fe-signalloom/base/netassert-signalloom.yaml}"
cmp --silent \
  "$canonical" \
  "$deployed"

command -v yq >/dev/null 2>&1 || {
  printf 'netassert contract validation requires mikefarah yq v4.\n' >&2
  exit 1
}

assert_case() {
  local name="$1" src_kind="$2" src_name="$3" src_ns="$4"
  local dst_kind="$5" dst_name="$6" dst_ns="$7" port="$8" expected="$9"
  local protocol="${10:-tcp}"
  NAME="$name" SRC_KIND="$src_kind" SRC_NAME="$src_name" SRC_NS="$src_ns" \
    DST_KIND="$dst_kind" DST_NAME="$dst_name" DST_NS="$dst_ns" \
    PORT="$port" EXPECTED="$expected" PROTOCOL="$protocol" yq -e '
      [.[] | select(
        .name == strenv(NAME) and
        .type == "k8s" and
        .protocol == strenv(PROTOCOL) and
        .src.k8sResource.kind == strenv(SRC_KIND) and
        .src.k8sResource.name == strenv(SRC_NAME) and
        .src.k8sResource.namespace == strenv(SRC_NS) and
        .dst.k8sResource.kind == strenv(DST_KIND) and
        .dst.k8sResource.name == strenv(DST_NAME) and
        .dst.k8sResource.namespace == strenv(DST_NS) and
        (.targetPort | tostring) == strenv(PORT) and
        (.exitCode | tostring) == strenv(EXPECTED)
      )] | length == 1' "$canonical" >/dev/null || {
        printf 'netassert contract missing or changed: %s\n' "$name" >&2
        return 1
      }
}

assert_same_destination() {
  local denied="$1" allowed="$2" denied_dst allowed_dst
  denied_dst="$(NAME="$denied" yq -o=json -I=0 '.[] | select(.name == strenv(NAME)) | [.protocol, .targetPort, .dst.k8sResource]' "$canonical")"
  allowed_dst="$(NAME="$allowed" yq -o=json -I=0 '.[] | select(.name == strenv(NAME)) | [.protocol, .targetPort, .dst.k8sResource]' "$canonical")"
  if [ -z "$denied_dst" ] || [ "$denied_dst" != "$allowed_dst" ]; then
    printf 'deny %s lacks same-destination healthy positive %s\n' "$denied" "$allowed" >&2
    return 1
  fi
}

assert_case envoy-gateway-to-dashboard-allowed pod envoy-gateway-pod ingress deployment dashboard-signalloom fe-signalloom 8080 0
assert_case generic-agent-to-spire-server-denied pod agent-patsy fe-signalloom-agents deployment spire-server inf-bao 8081 1
assert_case openbao-to-spire-server-allowed deployment openbao inf-bao deployment spire-server inf-bao 8081 0
assert_case dashboard-to-spire-server-denied deployment dashboard-signalloom fe-signalloom deployment spire-server inf-bao 8081 1
assert_case api-to-openbao-allowed deployment fe-signalloom fe-signalloom deployment openbao inf-bao 8200 0
assert_case dashboard-to-openbao-denied deployment dashboard-signalloom fe-signalloom deployment openbao inf-bao 8200 1
assert_case dashboard-to-supercred-runner-allowed deployment dashboard-signalloom fe-signalloom deployment supercred-demo-runner fe-signalloom 8000 0
assert_case api-to-supercred-runner-denied deployment fe-signalloom fe-signalloom deployment supercred-demo-runner fe-signalloom 8000 1
assert_case supercred-runner-to-api-allowed deployment supercred-demo-runner fe-signalloom deployment fe-signalloom fe-signalloom 8000 0
assert_case supercred-cardvault-agent-to-openbao-allowed pod netassert-cardvault-probe-pod fe-signalloom-agents deployment openbao inf-bao 8200 0
assert_case supercred-cardvault-agent-to-cardvault-allowed pod netassert-cardvault-probe-pod fe-signalloom-agents deployment cardvault inf-signalloom 8080 0
assert_case generic-agent-to-cardvault-denied pod agent-patsy fe-signalloom-agents deployment cardvault inf-signalloom 8080 1
assert_case policy-engine-self-allowed deployment policy-engine inf-signalloom deployment policy-engine inf-signalloom 8081 0
assert_case supercred-runner-to-policy-engine-denied deployment supercred-demo-runner fe-signalloom deployment policy-engine inf-signalloom 8081 1
assert_case supercred-runner-to-dns-udp-allowed deployment supercred-demo-runner fe-signalloom deployment coredns kube-system 53 0 udp
assert_case supercred-runner-to-dns-tcp-allowed deployment supercred-demo-runner fe-signalloom deployment coredns kube-system 53 0

assert_same_destination agents-to-api-denied dashboard-to-api-allowed
assert_same_destination agents-to-dashboard-denied envoy-gateway-to-dashboard-allowed
assert_same_destination agents-to-postgresql-denied api-to-postgresql-allowed
assert_same_destination dashboard-to-postgresql-denied api-to-postgresql-allowed
assert_same_destination dashboard-to-redis-denied api-to-redis-allowed
assert_same_destination generic-agent-to-spire-server-denied openbao-to-spire-server-allowed
assert_same_destination dashboard-to-spire-server-denied openbao-to-spire-server-allowed
assert_same_destination dashboard-to-openbao-denied api-to-openbao-allowed
assert_same_destination api-to-supercred-runner-denied dashboard-to-supercred-runner-allowed
assert_same_destination generic-agent-to-cardvault-denied supercred-cardvault-agent-to-cardvault-allowed
assert_same_destination supercred-runner-to-policy-engine-denied policy-engine-self-allowed

yq -e '[.[].name] | length == (unique | length)' "$canonical" >/dev/null || {
  printf 'netassert assertion names must be unique.\n' >&2
  exit 1
}

case "${1:-}" in
  "")
    printf 'netassert config drift validation passed.\n'
    ;;
  --catalogue-json)
    yq -o=json -I=2 '{
      "schemaVersion": "signalloom.netassert.catalogue/v1",
      "suiteId": "signalloom-network-policy",
      "source": "d2-signalloom/test/netassert-signalloom.yaml",
      "assertions": [.[] | {
        "id": .name,
        "protocol": .protocol,
        "port": .targetPort,
        "expectedExitCode": .exitCode,
        "source": .src.k8sResource,
        "destination": .dst.k8sResource
      }],
      "runtimePrerequisites": [
        {
          "placeholder": "agent-patsy",
          "namespace": "fe-signalloom-agents",
          "selector": "signalloom.ai/agent=true",
          "readyRequired": true,
          "failureMode": "fail-closed"
        },
        {
          "placeholder": "netassert-cardvault-probe-pod",
          "namespace": "fe-signalloom-agents",
          "selector": "app.kubernetes.io/name=cardvault-agent,signalloom.ai/supercred=true,bao.controlplane.io/consumer=cardvault-agent",
          "serviceAccount": "cardvault-agent",
          "lifecycle": "parent-provisioned-sustained",
          "readyRequired": true,
          "failureMode": "fail-closed"
        },
        {
          "placeholder": "envoy-gateway-pod",
          "namespace": "ingress",
          "selector": "gateway.envoyproxy.io/owning-gateway-name=cluster",
          "readyRequired": true,
          "failureMode": "fail-closed"
        }
      ]
    }' "$canonical"
    ;;
  *)
    printf 'usage: %s [--catalogue-json]\n' "$0" >&2
    exit 2
    ;;
esac
