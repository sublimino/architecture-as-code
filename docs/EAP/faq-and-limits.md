# Kusari pilot: known limits and what to do

This page lists what the tree at commit `dfc1a849` does not do for the pilot.
Each row names the file that proves it and what to do instead. It derives from the
status block and ADR-12 in
[the Spireless proposal](../Proposal%20—%20Signal%20Loom%20Spireless%20Token-Based%20Agent%20Identity%20Migration%20%282026-Q4%29.md),
from [`SLDC-MISSION-CERTIFICATION.md`](../eap/SLDC-MISSION-CERTIFICATION.md),
and from the code named in each answer.

## Summary table

| Limit | Proof | Effect on the pilot | Do this |
| :--- | :--- | :--- | :--- |
| The warden has no CA option and the hub certificate is self-signed | [`ebpf_correlator.go`](../../d2-signalloom/apps/stun-sentinel/pkg/correlator/ebpf_correlator.go) `httpClient`, [`cluster-issuer.yaml`](../../d2-infra/components/cert-manager/configs/base/cluster-issuer.yaml) | No observation and no stun record reaches the hub from the Kusari cluster | Ask ControlPlane for a certificate the nodes trust, or an image with the CA. Watch the spool. |
| `fleet-manager` cannot resolve a pod on another cluster | [`agent_resolution.go`](../../d2-signalloom/apps/fleet-manager/agent_resolution.go), [`fleet-config.yaml`](../../d2-signalloom/apps/fleet-manager/base/fleet-config.yaml) | A Kusari stun record answers `404 unknown agent`. The freeze holds with no central record. | Read the warden log and the pod annotation on the Kusari cluster. |
| A remote freeze is resumed only by a superadmin | [`fleet_operator.py`](../../d2-signalloom/apps/fe-signalloom/src/fleet_operator.py) | `POST /api/v1/fleet/resume/{agent}` sets `resume_requested`; the warden acts on its next poll. A `kusari-operator` cannot call it | Ask ControlPlane, or follow [enforcement](enforcement.md#how-to-resume) for the label write. |
| The remote-tenant overlay keeps the central tenant map | [`remote-tenant/kustomization.yaml`](../../d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/remote-tenant/kustomization.yaml) | Kusari observations carry `tenant_id: __unattributed__` and are invisible to a tenant user | Patch the ConfigMap. See [secondary-cluster](secondary-cluster.md#4-map-your-workloads-to-the-tenant). |
| A remote workload is listed but cannot be claimed | [`fleet_workloads.py`](../../d2-signalloom/apps/fe-signalloom/src/fleet_workloads.py), [`claim_tenancy.py`](../../d2-signalloom/apps/fe-signalloom/src/claim_tenancy.py) | Kusari workloads appear on `/agents` with `origin: "remote"`, but the claim path resolves against central discovery, so a remote pod has no governed record | Use the stub on the central cluster for the claim flow. Use `/weave` for Kusari signals. |
| A remote agent has no telemetry and no local pod | [`cadvisor_poller.py`](../../d2-signalloom/apps/fe-signalloom/src/cadvisor_poller.py) | The dossier's telemetry tab is empty for a remote agent: the poller scrapes this cluster's kubelet | Read the pod on the Kusari cluster. |
| The remote registry is unreadable without a read key | [`fleet_workloads.py`](../../d2-signalloom/apps/fe-signalloom/src/fleet_workloads.py) | With `FLEET_MANAGER_READ_KEY` unset, `/api/agents` reports `source_health_detail.remote_registry` as `unavailable` and lists no remote workload | Ask ControlPlane for a `fleet-manager` caller key with scope `read`. |
| The portal does not create Dex identities | [`invites.py`](../../d2-signalloom/apps/fe-signalloom/src/invites.py) | An invite binds a subject to a tenant, but the subject must already exist in Dex, which reads its config once at start | Ask ControlPlane for the Dex entry, then redeem the invite. See [onboarding](onboarding.md#1-get-an-identity). |
| Invites and bindings need the database | [`invites.py`](../../d2-signalloom/apps/fe-signalloom/src/invites.py) `_invites_pool` | With no database, `POST /api/v1/invites` and `/redeem` answer `503 database_unavailable`; only the `API_SUBJECT_TENANTS` map binds subjects | Ask ControlPlane for the environment map entry instead. |
| **Test Connection** proves the session, not the issuer URL | [`OnboardingWizard.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/components/onboarding/OnboardingWizard.tsx) `testConnection` | The wizard calls `GET /api/v1/me` with the token you already hold; the issuer fields are saved, not probed | Confirm a new issuer by logging in through it. |
| **Promote** on `/weave` is superadmin only and acts for the superadmin's own tenant | [`actor_promote.py`](../../d2-signalloom/apps/fe-signalloom/src/actor_promote.py), [`ingest_client.py`](../../d2-signalloom/apps/fe-signalloom/src/ingest_client.py) `acting_tenant` | A `kusari-operator` gets `403 superadmin_required`; a superadmin bound to `tenant-demo` gets `404` for a `kusari` actor, because a write never acts for another tenant | Ask ControlPlane. A provisional actor needs no promotion for the pilot. |
| The RBAC exporter is bound to the central cluster | [`rbac-exporter-cronjob.yaml`](../../d2-signalloom/infra/agent-swarm/signalloom-warden/rbac-exporter-cronjob.yaml) | Nothing on the Kusari cluster exports its own RBAC | Suspend the CronJob. Run the exporter script by hand and hand the JSON to ControlPlane. |
| The cAdvisor telemetry routes fail closed when discovery is down | [`cadvisor_poller.py`](../../d2-signalloom/apps/fe-signalloom/src/cadvisor_poller.py) | They are authenticated and tenant-scoped from the pod's `signalloom.ai/tenant` label, so an unreadable discovery service answers `503` rather than serving unfiltered samples | Check the discovery service. |
| The forensic bundle is produced by hand | [`package-eap-evidence.sh`](../../scripts/package-eap-evidence.sh) | No bundle appears when a freeze happens | Ask ControlPlane to run the packager after a containment run. |
| The AWS ingest and policy engine are not built | SLAWS proposal, section 8 | No AWS signals in the pilot yet | Prepare the read-only role from [`slaws-kusari-trust-policy.md`](../signalloom/slaws-kusari-trust-policy.md). |
| No test covers the remote-tenant path | [`test/signalloom-warden-manifests.bats`](../../test/signalloom-warden-manifests.bats) | The `/warden-ingest` and `/warden-fleet` routes have never been exercised by a suite | Run the checks in [secondary-cluster](secondary-cluster.md#5-check-the-network-path-and-tls) and report the result. |

## The warden cannot reach the hub

Symptom: the warden log shows `ingest_retryable_error` or `fleet_stun_failure`
with a TLS or connection error, and `/var/lib/signalloom/spool` fills.

Cause, in order of likelihood:

1. The name `dashboard.osramp.acme.local` does not resolve on the node.
2. Port 443 is not reachable. The lab gateway listens on NodePort `30754`.
3. The certificate chain does not validate. The central cluster uses a
   self-signed `ClusterIssuer`. The warden's HTTP clients use the Go default
   transport and the container's system roots. No environment variable and no
   mount adds a CA.

What to do: run the three checks in
[secondary-cluster](secondary-cluster.md#5-check-the-network-path-and-tls).
For cause 3, ask ControlPlane for one of two changes. The gateway can serve a
certificate from a CA that Kusari nodes trust. Or the image can carry the CA
in its system store. The spool
replays in order when the path returns, up to 256 MiB or 8 hours of batches.

Observations without a key are not spooled. If `SIGNAL_INGEST_TOKEN` is
unset the warden logs each observation and drops it. Check that the Secret
existed before the pod started.

## My cluster workloads are not on the Agents page

The portal gets the agent list from the discovery service in the central
cluster, which lists pods in two namespaces of that cluster. It does not read
the Kusari cluster. The warden on the Kusari cluster still observes and
freezes labelled pods, and still posts observations once the path works.
Those observations appear on `/weave` under tenant `kusari` when the tenant
map names the pod.

The claim flow exists for the pilot stub `agent-kusari` on the central
cluster. Use it to see a claim, a dossier, and the audit events. There is no
flow in this tree that registers a remote pod as a governed agent.

## RBAC analysis shows no Kusari cluster

The exporter CronJob needs the in-cluster portal Service and a Secret that
only exists on the central cluster, and the base leaves `AFM_CLUSTER_ID`
empty. The gateway has no prefix that routes to
`/api/v1/afm/clusters/import`. So nothing on the Kusari cluster can import
by itself.

`AFM_IMPORT_KEYS` now carries two key specs. One for the central cluster, one
for a remote cluster whose id is the `REMOTE_CLUSTER_ID` substitution. So a key
can be bound to the pilot cluster.

The binding is checked against the payload's `source_cluster`, the cluster the
RBAC was read from. The importer panel sends the selected cluster id there. The
check used to read `id`, which is the per-import identifier AFM sorts on. No key
binding could ever match it, so only a superadmin could import. A mismatch is
still `403 cluster_not_bound`.

What to do: suspend the CronJob on the Kusari cluster. For a one-off
analysis, run the exporter script by hand against the Kusari cluster. Save
the JSON and hand it to ControlPlane. A superadmin
can send it through **Send to AFM** on `/rbac-analysis`, which accepts the
signed-in superadmin's own token for any cluster id
([`afm_import.py`](../../d2-signalloom/apps/fe-signalloom/src/afm_import.py)).
The script is
[`rbac-exporter/export.py`](../../d2-signalloom/infra/agent-swarm/signalloom-warden/rbac-exporter/export.py).

## A pod is frozen and nobody can resume it

See [enforcement](enforcement.md#how-to-resume). On the Kusari cluster the
release is a label write on that cluster. Capture the evidence first: the
pod object, `cgroup.events`, and the warden log.

## The Fleet page is not there

`/fleet` is superadmin-only. `kusari-operator` is not a superadmin and is
redirected to `/agents`. The page shows the five demo agents of the central
cluster, not the pilot. Nothing on it applies to a Kusari pod.

## Who is the superadmin

`demo-user@signalloom.local`. The portal and the dashboard both match that
name. There is no role table and no group claim. A superadmin acts for every
tenant on reads of `signal-ingest`. It may also stun through the portal,
import RBAC for any cluster, and open the demo pages. The pilot identity has none of
that.

## Which certification record is current

[`SLDC-MISSION-CERTIFICATION.md`](../eap/SLDC-MISSION-CERTIFICATION.md) and
[`SLDC-P5-1-E2E-CONTAINMENT.md`](../eap/SLDC-P5-1-E2E-CONTAINMENT.md).
[`FINAL-MISSION-CERTIFICATION-REPORT.md`](../eap/FINAL-MISSION-CERTIFICATION-REPORT.md)
reports a full pass on the same date and does not match the live runs. The
proposal's status block records a cold-start rebuild that fixed eleven defects
after those records were written, so the code is ahead of both.

## What is planned

| Item | Where it is tracked |
| :--- | :--- |
| OpenBao as the authority for probe credentials, with leases | ADR-02 in the Spireless proposal, deferred to Phase 2 |
| Probe batching and spool chain checks at the hub | Spireless proposal, Phase 2 wire contract |
| AWS CloudTrail ingest, CEL policy bundles, findings as observations | SLAWS proposal, P1 to P4-GOV |
| The forensic bundle schema aligned with the observation wire format | Not tracked. See [enforcement](enforcement.md#the-forensic-bundle). |
| A CA option for the warden | Not tracked in any proposal in this tree |
| Claiming a remote pod as a governed agent | Not tracked in any proposal in this tree |
| Cross-tenant **Promote** for a superadmin | Not tracked in any proposal in this tree |
