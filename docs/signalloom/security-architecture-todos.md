# Security architecture to-dos

This register records each security control that the platform relaxed or did
not yet build, until the enterprise security architecture documentation is
complete. Each entry has an id, the decision, the blast radius, the
compensating controls, the candidate replacements, and an exit criterion.

An entry stays open until its exit criterion is met. Close an entry with a
dated line that names the commit that met the criterion. Do not delete it.

| Id | Title | Status | Opened |
| :--- | :--- | :--- | :--- |
| [SA-TODO-001](#sa-todo-001-public-https-egress-for-the-portal-pod) | Public HTTPS egress for the portal pod | Open, exemption in force | 2026-10-16 |
| [SA-TODO-002](#sa-todo-002-unbounded-api-transport-egress-on-two-runner-pods) | Unbounded API transport egress on two runner pods | Open, finding | 2026-10-16 |
| [SA-TODO-003](#sa-todo-003-connector-credentials-are-not-in-openbao) | Connector credentials are not in OpenBao | Open, finding | 2026-10-17 |

## SA-TODO-001: public HTTPS egress for the portal pod

**Decision.** The principal accepted this exemption on 2026-10-16. The
decision, in the principal's words, is quoted as given. The style check is
off for the quote only.

<!-- docs-lint: off -->
> Seeing as our enterprise architecture documentation is not yet complete, we
> need to leave a security exemption for this behaviour and for now allow
> public internet egress. This is not something we'll do in future.
<!-- docs-lint: on -->

**What was relaxed.** The `fe-signalloom` namespace is default-deny for
ingress and egress. The NetworkPolicy `allow-portal-public-https-egress` now
lets the portal pod open TCP 443 to public IPv4 addresses. The policy is in
`d2-signalloom/apps/fe-signalloom/base/networkpolicy.yaml`. Its annotations
carry the id `SA-TODO-001`, the decision date, the reason, and the
replacement.

**Why.** The live AI provider connectors run in the portal. They must reach
`api.anthropic.com` and `api.openai.com`. Before the exemption, a connection
from the pod to `160.79.104.10:443` timed out. The cluster CNI is kindnet. It
applies plain Kubernetes NetworkPolicy, which has no rule for a host name. The
provider IP addresses are not stable, so an IP allow-list would break without
warning.

**Blast radius.**

- One workload: the `fe-signalloom` Deployment. The selector needs both
  `app.kubernetes.io/name: fe-signalloom` and `bao.controlplane.io/consumer:
  fe-signalloom`. The bao-spire proof Jobs carry only the second label, so
  they do not get the grant.
- Both containers in that pod get the grant, because NetworkPolicy applies to
  the pod. These are `discovery-portal` and the `kubectl-proxy` sidecar.
- Any public IPv4 host on TCP 443, not only the AI providers. A compromised
  portal process can send data to any HTTPS endpoint on the internet. This is
  the residual risk that the principal accepted.
- No new in-cluster path. The `except` list removes 10.0.0.0/8,
  172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 and
  127.0.0.0/8. It also names the kind pod range 10.244.0.0/16 and the service
  range 10.96.0.0/12, so that a later edit to 10.0.0.0/8 cannot open them.
- No IPv6. The pods have no IPv6 route.

**Compensating controls.**

- Only the portal pod, and only TCP 443.
- Connector credentials are sealed at rest with AES-256-GCM, bound to the
  tenant and the connector. The code is
  `d2-signalloom/apps/fe-signalloom/src/connector_credentials.py`. The key is
  in a mounted Secret, not in the manifest.
- The portal opens provider connections only for connectors that a tenant
  configured.
- `d2-signalloom/test/portal-public-egress.bats` pins the policy shape. It
  fails if the selector, the port, the peer, or the `except` list widens. It
  also fails if another policy in the namespace grants public egress.
- `scripts/portal-egress-probe.sh` proves the result on a live cluster. It
  checks provider reach, and it checks that an unlisted private address still
  times out.

**Candidate replacements.** The principal named three. The security
architecture documentation will select one.

1. An L7 egress proxy with an FQDN allow-list. The portal sends provider
   traffic through the proxy, and the NetworkPolicy allows only the proxy.
2. A service mesh egress gateway. The mesh controls egress by host name and
   adds mTLS and per-request audit.
3. An eBPF or Cilium FQDN policy. A `CiliumNetworkPolicy` with `toFQDNs`
   allows only the provider host names. This needs Cilium as the CNI in place
   of kindnet.

**Exit criterion.** Close this entry when all of these are true:

- The security architecture documentation selects a replacement.
- The portal reaches the providers through that replacement, and the
  replacement allows only the configured provider host names.
- `allow-portal-public-https-egress` is deleted from the manifests.
- `scripts/portal-egress-probe.sh` passes against the replacement, and a host
  that is not on the allow-list fails.

**Verification.**

```bash
bats d2-signalloom/test/portal-public-egress.bats
bats d2-signalloom/test/portal-egress-probe.bats
scripts/portal-egress-probe.sh --context kind-osramp
```

## SA-TODO-002: unbounded API transport egress on two runner pods

**Status.** This is a finding. No decision authorised it. It was found while
the SA-TODO-001 tests were written.

**What it is.** Two policies in `fe-signalloom` have an egress rule with no
`to` field. Such a rule allows every destination on its ports.

| Policy | Pods | Ports |
| :--- | :--- | :--- |
| `allow-netassert-runner-egress` | The `netassert-run` Job (`signalloom.ai/purpose: network-test-run`) | TCP 443, TCP 6443 |
| `allow-supercred-demo-runner-egress` | `supercred-demo-runner` | TCP 443, TCP 6443 |

Both rules exist so that the pod can reach the kube-apiserver. Because they
have no `to` field, both pods can also reach any public host on 443. This was
true before SA-TODO-001.

**Blast radius.** The supercred demo runner executes privileged demo scripts
against the cluster. Public 443 egress from it is a data-exfiltration path.

**Candidate fix.** Bound each rule to the cluster service range and the node
network, as `allow-portal-dependencies` does for its kube-apiserver rule. The
three SA-TODO-001 replacements also cover this case.

**Exit criterion.** Close this entry when neither policy has an egress rule
without a `to` field. The test "the set of policies with an unbounded egress
rule does not grow" in `d2-signalloom/test/portal-public-egress.bats` pins the
two current names. Update it in the same commit.

## SA-TODO-003: connector credentials are not in OpenBao

**Status.** This is a finding against the platform secrets standard: every
platform secret is stored in OpenBao. The principal set the standard on
2026-10-17, after this store shipped.

**What it is.** Connector credentials (provider API keys, admin keys and
workspace identifiers held with them) are sealed with AES-256-GCM in
`public.tenant_connectors.credentials_ciphertext`. The sealing key is read
from the `fe-signalloom/fe-signalloom-connector-credential-key` Kubernetes
Secret, minted by `make connector-credential-key`. The code is
`d2-signalloom/apps/fe-signalloom/src/connector_credentials.py`.

**Blast radius.** Anyone who can read both the database and that Secret can
decrypt every tenant's provider credentials. OpenBao's per-path policy,
leases and audit log do not cover these reads.

**Compensating controls.** The ciphertext is bound to tenant and connector as
associated data, so a row moved to another tenant does not decrypt. Without
the key, credential writes fail with 503. The portal pod is the only reader.

**Candidate fix.** Store each credential in OpenBao KV v2 under a per-tenant
path, for example `signalloom/tenants/<tenant>/connectors/<connector_id>`.
Keep only that path in Postgres. The portal authenticates to OpenBao with its
workload identity, under a policy that grants each tenant path read and write.
The portal already has egress to `inf-bao:8200`. Migrate existing rows, then
delete the sealing key Secret.

**Exit criterion.** Close this entry when no connector secret is stored
outside OpenBao and the sealing key Secret no longer exists.
