# Netassert runner integration contract

The parent integration owns manifests and suite content. This runtime requires:

## RBAC

The `netassert-runner` ServiceAccount needs these read-only resolver permissions:

- `list` pods in `fe-signalloom-agents` for label `signalloom.ai/agent=true`.
- `get` each suite destination `pod` in its declared namespace.
- `get` each suite destination `deployment`, `statefulset`, or `daemonset`.

Netassert separately requires its existing source-resource reads and
`patch` on source `pods/ephemeralcontainers`. Do not grant destination
ephemeral-container patching solely for resolver validation.

## Suite ConfigMap

Mount the immutable suite as `/config/netassert-signalloom.yaml`. Agent source
entries use the exact placeholder `name: agent-patsy`; the resolver writes only
the substituted copy at `/work/netassert-run.yaml`. Each destination must use a
`dst.k8sResource` of kind `pod`, `deployment`, `statefulset`, or `daemonset`.
Unsupported or unavailable destinations fail the Job before Netassert runs, so
an expected connection failure cannot be presented as policy-denial evidence.

## Pinned helper images

The fixed Job invokes these immutable multi-platform image-index digests:

- `docker.io/controlplane/netassertv2-l4-client@sha256:9b040bbe53cf0ffc6a9dd46570d463b0603aa90c69ad2d5f52836d2cea1464ff`
- `docker.io/controlplane/netassertv2-packet-sniffer@sha256:faa2252d5fdfad998f2cef228c2ae1fd6a4a5f626dfb580175f09a1018054a04`

The parent image lifecycle must pull and load both digests into Kind before a
scan. The runner intentionally does not fall back to mutable `:latest` tags.
