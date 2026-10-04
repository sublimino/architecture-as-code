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
| No product path resumes a freeze on a remote cluster | [`stunhold.go`](../../d2-signalloom/apps/signalloom-stun-sentinel/stunhold.go), [`health.go`](../../d2-signalloom/apps/signalloom-stun-sentinel/health.go) | A frozen Kusari pod stays frozen until a label write or a delete on that cluster | Follow [enforcement](enforcement.md#how-to-resume). |
| The remote-tenant overlay keeps the central tenant map | [`remote-tenant/kustomization.yaml`](../../d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/remote-tenant/kustomization.yaml) | Kusari observations carry `tenant_id: __unattributed__` and are invisible to a tenant user | Patch the ConfigMap. See [secondary-cluster](secondary-cluster.md#4-map-your-workloads-to-the-tenant). |
| The agent list reads the central cluster only | [`api_compat.py`](../../d2-signalloom/apps/fe-signalloom/src/api_compat.py) `AGENT_DISCOVERY_URL`, [`server.py`](../../d2-signalloom/apps/fake-integration-proxy/server.py) | Kusari workloads are not on `/agents` and cannot be claimed | Use `/weave` for Kusari signals. Use the stub on the central cluster for the claim flow. |
| The agent list is not tenant-filtered | [`api_compat.py`](../../d2-signalloom/apps/fe-signalloom/src/api_compat.py) `agents()` | Every user sees every discovered workload | Treat registry rows and claims as the tenant boundary, not the list. |
| No invite or signup route | [`onboarding.py`](../../d2-signalloom/apps/fe-signalloom/src/onboarding.py), [`RedeemInvite.tsx`](../../d2-signalloom/apps/dashboard-signalloom/src/pages/RedeemInvite.tsx) | New users are a Dex config edit plus a subject map edit | Ask ControlPlane. See [onboarding](onboarding.md#1-get-an-identity). |
| The RBAC exporter and importer are bound to the central cluster | [`rbac-exporter-cronjob.yaml`](../../d2-signalloom/infra/agent-swarm/signalloom-warden/rbac-exporter-cronjob.yaml), [`fe-signalloom/base/deployment.yaml`](../../d2-signalloom/apps/fe-signalloom/base/deployment.yaml) `AFM_IMPORT_KEYS` | `/rbac-analysis` and `/collusion-access` show no Kusari cluster | Suspend the CronJob. Hand ControlPlane an RBAC export for a superadmin import. |
| Four cAdvisor telemetry routes answer without a token | [`cadvisor_poller.py`](../../d2-signalloom/apps/fe-signalloom/src/cadvisor_poller.py), [`SLDC-P5-CHECKLIST-AUDIT.md`](../eap/SLDC-P5-CHECKLIST-AUDIT.md) | Anyone who reaches the gateway can read agent CPU samples | Known to ControlPlane. Do not expose the gateway beyond the pilot network. |
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
empty. The static import key is bound to cluster `kind-osramp`. The gateway
has no prefix that routes to `/api/v1/afm/clusters/import`. So nothing on the
Kusari cluster can import.

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
| A remote-cluster resume path | Not tracked in any proposal in this tree |
| A CA option for the warden | Not tracked in any proposal in this tree |
| `fleet-manager` inventory of remote pods | Not tracked in any proposal in this tree |
