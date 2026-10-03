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
# The door was open and the handshake still failed: the client dialled the
# TLS-only server API in plaintext and every credential restore died live with
# "error reading server preface: EOF" (2026-10-03). The client now takes an
# X509-SVID from the Workload API (spire_client.go spireTransportFor; the
# handshake itself is proven in spire_mtls_test.go). The last tests here pin
# the two manifest halves that needs: the fleet-manager container mounts the
# agent socket and names it in SPIFFE_ENDPOINT_SOCKET, and the server grants
# fleet-manager's SPIFFE ID admin, without which the Entry API refuses the
# eviction and re-creation calls even over mTLS.

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
  infra="$(kubectl kustomize "$repo_root/d2-signalloom/infra/inf-bao/configs/base")"
  app="$(kubectl kustomize "$repo_root/d2-signalloom/apps/fleet-manager/base")"
  controllers="$(kubectl kustomize "$repo_root/d2-signalloom/infra/inf-bao/controllers/base")"
}

fleet_manager_container() {
  yq -e 'select(.kind == "Deployment" and .metadata.name == "fleet-manager")
         | .spec.template.spec.containers[] | select(.name == "fleet-manager")' <<<"$app"
}

server_conf() {
  yq -e 'select(.kind == "ConfigMap" and .metadata.name == "spire-server-config") | .data["server.conf"]' <<<"$controllers"
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

@test "the fleet-manager container names a SPIRE agent socket it actually mounts" {
  container="$(fleet_manager_container)"
  run yq -e '.env[] | select(.name == "SPIFFE_ENDPOINT_SOCKET") | .value' <<<"$container"
  [ "$status" -eq 0 ]
  socket="$output"
  # The socket's directory must be a read-only mount of the spire-sockets
  # volume on THIS container, not only on the spire-helper sidecar.
  run yq -e '.volumeMounts[] | select(.name == "spire-sockets") | .mountPath + " " + (.readOnly | tostring)' <<<"$container"
  [ "$status" -eq 0 ]
  [ "$output" = "/run/spire/sockets true" ]
  [ "$socket" = "unix:///run/spire/sockets/agent.sock" ]
}

@test "the spire-server grants fleet-manager's SPIFFE ID admin on the server API" {
  conf="$(server_conf)"
  td="$(sed -n 's/.*server {[^}]*trust_domain[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$conf" | head -1)"
  [ "$td" = "signalloom.demo" ]
  ns="$(yq -e 'select(.kind == "Deployment" and .metadata.name == "fleet-manager") | .metadata.namespace' <<<"$app")"
  sa="$(yq -e 'select(.kind == "Deployment" and .metadata.name == "fleet-manager") | .spec.template.spec.serviceAccountName' <<<"$app")"
  want="spiffe://$td/ns/$ns/sa/$sa"
  [ "$want" = "spiffe://signalloom.demo/ns/fe-signalloom/sa/fleet-manager" ]
  # Inside the server block, not some plugin's: admin_ids is a server setting.
  admins="$(sed -n 's/.*server {[^}]*admin_ids[[:space:]]*=[[:space:]]*\[\([^]]*\)\].*/\1/p' <<<"$conf" | head -1)"
  [ "$admins" = "\"$want\"" ]
}
