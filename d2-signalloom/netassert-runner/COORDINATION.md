# Netassert runner integration contract

The parent integration owns manifests and suite content. This runtime requires:

## RBAC

The `netassert-runner` ServiceAccount needs these read-only resolver permissions:

- `list` pods in `fe-signalloom-agents` for the generic-agent selector.
- `list` pods in `fe-signalloom-agents` for the SuperCred selector.
- `list` pods in `ingress` for the owning-Gateway selector.
- `get` each suite destination `pod` in its declared namespace.
- `get` each suite destination `deployment`, `statefulset`, or `daemonset`.

Netassert separately requires its existing source-resource reads and
`patch` on source `pods/ephemeralcontainers`. Do not grant destination
ephemeral-container patching solely for resolver validation.

## Suite ConfigMap

Mount the immutable suite as `/config/netassert-signalloom.yaml`. The resolver
supports these fixed source placeholders and no caller-provided mappings:

- `agent-patsy` → `fe-signalloom-agents`, `signalloom.ai/agent=true,signalloom.ai/framework=custom,netassert.signalloom.ai/fixture=generic-agent`.
- `envoy-gateway-pod` → `ingress`, `gateway.envoyproxy.io/owning-gateway-name=cluster`.
- `netassert-cardvault-probe-pod` → `fe-signalloom-agents`,
  `app.kubernetes.io/name=cardvault-agent,signalloom.ai/supercred=true,bao.controlplane.io/consumer=cardvault-agent,netassert.signalloom.ai/fixture=cardvault-agent`.

The Cardvault entry is a fleet-provisioned sustained fixture using a tokenless
ServiceAccount `cardvault-agent` owned in `fe-signalloom-agents` by the same
fixture ResourceSet. The resolver excludes Job-owned pods, so the transient
`supercred-agent-run-*` Job can never satisfy this prerequisite. The fixture
must remain Running and Ready for the complete Netassert scan lifecycle.

For each placeholder present in the suite, exactly one Running, Ready,
non-terminating candidate must remain after the Job-owner exclusion. Zero or
multiple candidates fail closed rather than selecting by Kubernetes list order.

The resolver writes only the substituted copy at `/work/netassert-run.yaml`.
Each destination must use a `dst.k8sResource` of kind `pod`, `deployment`,
`statefulset`, or `daemonset`.
Unsupported or unavailable destinations fail the Job before Netassert runs, so
an expected connection failure cannot be presented as policy-denial evidence.

## TAP validator

`/usr/local/bin/validate-tap.sh TAP_FILE` accepts Netassert TAP version 14 only
when it has exactly one positive plan, one uniquely numbered result per plan
entry, no out-of-plan numbering, no malformed top-level records, and no
bailout. Complete `not ok` assertions are valid TAP and retain Netassert's exit
status `1`; absent or structurally invalid TAP changes the Job status to `2`.
The controller's fixed command prints the marker and TAP before validation
affects completion. GitOps should invoke scans through the controller only;
there is no supported host-side runner bypass.

## Pinned helper images

The fixed Job invokes these immutable multi-platform image-index digests:

- `docker.io/controlplane/netassertv2-l4-client@sha256:9b040bbe53cf0ffc6a9dd46570d463b0603aa90c69ad2d5f52836d2cea1464ff`
- `docker.io/controlplane/netassertv2-packet-sniffer@sha256:faa2252d5fdfad998f2cef228c2ae1fd6a4a5f626dfb580175f09a1018054a04`

The parent image lifecycle must pull and load both digests into Kind before a
scan. The runner intentionally does not fall back to mutable `:latest` tags.
