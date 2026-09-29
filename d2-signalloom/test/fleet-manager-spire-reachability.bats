#!/usr/bin/env bats
#
# Guard: fleet-manager can reach the SPIRE server API on :8081.
#
# The cascade already attempts SPIRE eviction (k8sclient.go revokeSpirePlane),
# but on kind every attempt died with DeadlineExceeded: inf-bao's default-deny
# admitted nothing from fe-signalloom to spire-server, and fleet-manager's own
# NetworkPolicy allowed egress to :8200 only. Both halves are asserted here
# against the RENDERED manifests, and the ingress selector is checked against
# the label the rendered fleet-manager pod template actually carries, so a
# relabel on either side goes red instead of silently closing the door.
#
# Scope: network reachability only. It does not prove the gRPC handshake: the
# SPIRE client dials with insecure credentials and the server API is TLS.

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
  infra="$(kubectl kustomize "$repo_root/d2-signalloom/infra/inf-bao/configs/base")"
  app="$(kubectl kustomize "$repo_root/d2-signalloom/apps/fleet-manager/base")"
}

@test "inf-bao admits fleet-manager to spire-server on TCP 8081" {
  run yq -e '
    select(.kind == "NetworkPolicy" and .spec.podSelector.matchLabels["app.kubernetes.io/name"] == "spire-server")
    | .spec.ingress[]
    | select(.from[] | (.namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "fe-signalloom"
                        and .podSelector.matchLabels["app.kubernetes.io/name"] == "fleet-manager"))
    | .ports[] | select(.port == 8081 and .protocol == "TCP") | .port' <<<"$infra"
  [ "$status" -eq 0 ]
  [ "$output" = "8081" ]
}

@test "the ingress rule's pod label is one the fleet-manager pod template carries" {
  run yq -e 'select(.kind == "Deployment" and .metadata.name == "fleet-manager")
             | .spec.template.metadata.labels["app.kubernetes.io/name"]' <<<"$app"
  [ "$status" -eq 0 ]
  [ "$output" = "fleet-manager" ]
}

@test "the spire-server ingress for fleet-manager opens 8081 only" {
  # Exactly one port, so this rule cannot quietly become a general door.
  # eval-all: the count must span every rendered document, not one at a time.
  run yq ea -e '
    [select(.kind == "NetworkPolicy" and .spec.podSelector.matchLabels["app.kubernetes.io/name"] == "spire-server")
     | .spec.ingress[]
     | select(.from[] | .podSelector.matchLabels["app.kubernetes.io/name"] == "fleet-manager")
     | .ports[]] | length' <<<"$infra"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "fleet-manager's own policy allows egress to spire-server on TCP 8081" {
  run yq -e '
    select(.kind == "NetworkPolicy" and .metadata.name == "fleet-manager")
    | .spec.egress[]
    | select(.to[] | (.namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "inf-bao"
                      and .podSelector.matchLabels["app.kubernetes.io/name"] == "spire-server"))
    | .ports[] | select(.port == 8081 and .protocol == "TCP") | .port' <<<"$app"
  [ "$status" -eq 0 ]
  [ "$output" = "8081" ]
}
