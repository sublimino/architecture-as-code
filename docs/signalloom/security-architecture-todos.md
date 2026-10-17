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
| [SA-TODO-003](#sa-todo-003-connector-credentials-are-not-in-openbao) | Connector credentials are not in OpenBao | Open, finding, blocked on persistent OpenBao | 2026-10-17 |

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

**Blocker (found 2026-10-17).** The OpenBao server in `inf-bao` cannot hold
these credentials yet. It runs `bao server -dev` from image
`quay.io/openbao/openbao:2.1.1`. In dev mode, storage is `inmem` and HA
is off. There is one Shamir key share, and the root token is the static value
`signalloom-demo-root-token`. A pod restart loses every secret. The manifest is
[`openbao-spire.yaml`](../../d2-signalloom/infra/inf-bao/controllers/base/openbao-spire.yaml).
If connector credentials moved there now, a restart would erase them, and the
old sealed copies would be gone after migration. The credential move waits
for phase 1 below.

**Facts that the plan depends on (checked on `kind-osramp`, 2026-10-17).**

- The portal has a SPIFFE identity and an OpenBao role today. The role
  `signalloom-fe-signalloom` on mount `auth/jwt` binds
  `spiffe://signalloom.demo/ns/fe-signalloom/sa/fe-signalloom`, audience
  `openbao`. It gives batch tokens with a 5-minute TTL. It can read only
  `kv/data/signalloom/fe-signalloom`. The portal Deployment does not log in
  yet.
- `fleet-manager` already uses the login pattern that the portal needs. A
  `jwt-svid` sidecar writes the JWT-SVID to a file. A bao agent sidecar logs in
  and writes the token to `/var/run/secrets/openbao/token`. The client reads
  the file again for each request. The config is
  [`openbao-agent-config.yaml`](../../d2-signalloom/apps/fleet-manager/base/openbao-agent-config.yaml).
- A KV v2 mount `kv/` exists. The new paths can use it. No new mount is
  necessary.
- The `inf-signalloom` Postgres is a single `postgres:16-alpine` Deployment. Its
  data is on the node hostPath `/var/local/signalloom-postgres-data`, not on a
  PVC. Its superuser password is plain text in
  [`dependencies.yaml`](../../d2-signalloom/infra/inf-signalloom/controllers/base/dependencies.yaml).
  The SQL in `docker-entrypoint-initdb.d` runs only on an empty data
  directory. Thus a new role and database for OpenBao need a separate
  idempotent Job.
- 30 tracked files contain the static root token. They are the four
  setup Jobs in `inf-bao/configs`, the `openbao-agent-generic-role-setup`
  Job, the `spire-openbao-sync` CronJob (each run), and host scripts and tests.
  The host scripts include `scripts/demo-lifecycle.sh`,
  `scripts/swarm-seed-secrets.sh`, `scripts/kagent-credentials.sh` and
  `scripts/supercred-demo.sh`.

**Decisions for the principal.** Phase 1 cannot start until these have
answers. Each item gives a recommendation.

1. Unseal model on kind. The options are manual Shamir unseal by an operator,
   auto-unseal from a second OpenBao Transit server, or a static unseal key in
   a Kubernetes Secret. Manual unseal stops the unattended cold-start standup.
   A second server must also unseal. A key in a Secret conflicts with the
   Secrets rule in `AGENTS.md`. Recommendation: a static unseal key in a
   Secret on kind only, recorded as a new SA-TODO exception. Use cloud KMS
   auto-unseal on the GCP lane. Check that OpenBao 2.7.1 supports a static
   seal before you build on it.
2. Administration without a root token. Recommendation: an init Job runs
   `bao operator init` once. It writes the unseal key to the Secret from
   decision 1, and it keeps the root token in memory only. It creates a JWT
   role `inf-bao-admin` bound to one SPIFFE ID, with a policy for `sys/mounts`,
   `sys/policies`, `sys/auth` and the `auth/jwt` roles. Then it revokes the
   root token. All setup Jobs and the sync CronJob log in with that role.
   Host scripts get a short-lived token from
   `bao operator generate-root` or from that role through `kubectl exec`.
3. Credential for the OpenBao storage. OpenBao needs its Postgres password
   before it can start, so that password cannot be in OpenBao.
   Recommendation: keep it in a Kubernetes Secret and record it as an SA-TODO
   exception. The Postgres superuser password is already in plain text.
4. HA and TLS. Recommendation: one replica and plain HTTP on kind for now.
   Postgres storage permits HA later. Record TLS on port 8200 as an SA-TODO
   entry.
5. Data on the change of server. The `inmem` data is lost when the server
   changes. Recommendation: accept this. The setup Jobs and seed scripts write
   all of it again, and live agent tokens and leases expire. Plan one
   maintenance window, then restart the agents.

**Plan, phase 1: persistent OpenBao.** Work in `d2-signalloom/infra/inf-bao`
through GitOps. Each step is one commit with a test.

1. Add a Job in `inf-signalloom` that creates the role `openbao` and the
   database `openbao`. It must be idempotent. It must run on a live cluster.
   Add the `kv_store` table and the `ha_enabled` setting from the OpenBao
   PostgreSQL storage documentation.
2. Add a NetworkPolicy rule from `inf-bao` to `inf-signalloom:5432` for the
   OpenBao pod only. Add the NetAssert cases for the rule.
3. Replace the dev server with a `server` config: `storage "postgresql"`,
   `listener "tcp"` on 8200, the seal from decision 1, and image
   `quay.io/openbao/openbao:2.7.1`. Read the release notes from 2.1.1 to
   2.7.1 for changes to the JWT auth method, KV v2 and the agent first.
4. Add the init Job from decision 2. If the server is already initialised, the
   Job does nothing.
5. Change the four setup Jobs, the generic role Job and the sync CronJob to log
   in with `inf-bao-admin`. Their `bao` commands stay the same and stay
   idempotent. Add `kustomize.toolkit.fluxcd.io/force: Enabled` where a pod
   template changes.
6. Change the host scripts to get a token as in decision 2. Remove
   `signalloom-demo-root-token` from every tracked file. Add a test that fails
   if the string comes back.
7. Proof: restart the OpenBao pod. Check that `kv/signalloom/fe-signalloom`
   is still there, that every role still logs in, and that the
   `bao-spire-positive-proof` Job passes.

**Plan, phase 2: connector credentials in OpenBao.** Start only after phase 1
step 7 passes.

1. KV layout: `kv/data/signalloom/tenants/<tenant_id>/connectors/<connector_id>`.
   Postgres keeps the path and the KV version in new columns of
   `public.tenant_connectors`. The portal stops writing
   `credentials_ciphertext`.
2. Policy: add
   `path "kv/data/signalloom/tenants/+/connectors/+" { capabilities = ["create", "read", "update"] }`
   and
   `path "kv/metadata/signalloom/tenants/+/connectors/+" { capabilities = ["delete"] }`
   to `signalloom-fe-signalloom`. The portal is one identity for all tenants.
   Per-tenant OpenBao policies would need one SPIFFE identity for each tenant,
   which the portal does not have. Thus the tenant-scoped code paths in the
   portal enforce isolation, and the KV path includes the tenant id from the
   checked principal.
3. Login: add the `jwt-svid` and bao agent sidecars to the portal, as in
   `fleet-manager`. The portal reads `BAO_TOKEN_FILE` for each request.
4. Code: a KV client behind an injectable seam, with a fake for tests. If
   OpenBao cannot be reached, a credential read or write answers 503
   `credential_store_unavailable`. It never uses plain text or the old sealed
   copy. Disconnect deletes the KV metadata, which removes all versions.
   Fixture mode keeps the in-memory store.
5. Migration: a one-shot script, dry run by default. It reads each sealed row
   with the old key and writes the value to OpenBao. Then it reads it back,
   sets the reference and sets the ciphertext to null. A second run makes no
   change. It reports the counts.
6. After the migration is correct on the live cluster, delete the
   `fe-signalloom-connector-credential-key` Secret and the
   `make connector-credential-key` target.

**Exit criterion.** Close this entry when no connector secret is stored
outside OpenBao and the sealing key Secret no longer exists.
