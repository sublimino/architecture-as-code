# Signal Loom containment-evidence ownership

Generated from [stun-evidence-ownership.json](stun-evidence-ownership.json) by `node scripts/render-stun-evidence-ownership.mjs` — do not hand-edit this file.

Classification captured on kind-osramp on 2026-08-31. A store is useful as containment evidence only if its writer is independent of the action being witnessed and its record outlives the reconciler or process that can erase the action.

## Classification

| store | physical location | writing process | managedFields manager observed on the live cluster | inside-or-outside the reconciled set | what deletes or reverts it | worst-case lifetime | evidence class |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Pod state label plus stunned annotations | fe-signalloom-agents/Pod agent-sir-lancelot metadata | Flux Operator materializes the ResourceSet; kubelet updates Pod status | flux-operator, kubelet | INSIDE — agent-inventory Kustomization is Flux reconciled | Flux/Kustomize desired-state apply except configured ignore paths; Pod replacement deletes it | Until Pod replacement; ordinary reconcile survival is limited to the declared ignored paths | MEASURED |
| public.audit_events relation | signalloom database in inf-signalloom/postgresql Pod writable container layer | fe-signalloom application inserts rows; migration 030 trigger rejects mutation | N/A for PostgreSQL relation; hosting Deployment: kustomize-controller, kube-controller-manager | INSIDE — inf-signalloom/infra-controllers Kustomization has prune=true | PostgreSQL Deployment Pod recreation; Flux prune deleting its Deployment; sanctioned data-reset disables trigger | Until current PostgreSQL Pod recreates; no StatefulSet or PVC exists | MEASURED |
| Kubernetes Event series | Kubernetes Events API/etcd | kube-apiserver persists Event objects and aggregates repeated series | N/A — no unexpired containment Event existed at capture time | OUTSIDE — apiserver-managed runtime data | kube-apiserver event TTL garbage collection | UNVERIFIED effective value: running kube-apiserver command has no explicit --event-ttl flag | INFERRED |
| scripts/supercred-evidence.sh output | Caller stdout only | Shell reader formats live kubectl query output | N/A — this is a reader, not a stored Kubernetes object | OUTSIDE — ephemeral process output | Process exit; subsequent run rereads current Pod metadata | One process invocation | MEASURED |
| Dashboard SuperCred projection | Browser/dashboard process memory derived from live API response | supercredProjection.ts projects current SuperCred state for the UI | N/A — this is a reader/projection, not a stored Kubernetes object | OUTSIDE — ephemeral process projection | Next API poll, refresh, or dashboard restart replaces displayed state | Until next projection refresh | MEASURED |
| OpenBao credential lease or role revocation | OpenBao in-memory storage and JWT auth backend | Containment workflow calls OpenBao API | N/A — OpenBao data is not a Kubernetes managedFields object | OUTSIDE — runtime OpenBao enforcement state | OpenBao lease expiry, explicit renewal, role/KV recreation, or OpenBao Pod restart | Until OpenBao Pod restart because live bao status reports Storage Type inmem | MEASURED |
| kustomize-controller configured Event | Kubernetes Events API/etcd | kustomize-controller emits configured reconciliation Events | N/A — current agent-sir-lancelot configured Event query returned zero unexpired objects | OUTSIDE — apiserver-managed runtime Event data | kube-apiserver event TTL garbage collection and Event-series aggregation | UNVERIFIED effective event TTL; a recorded historical measurement was 36 configured occurrences | INFERRED |

## RECORDED DECISION

**System of record: none of the currently deployed stores is acceptable.** `public.audit_events` is the required P6-1 target only after its storage is made independent of the reconciled disposable PostgreSQL Pod. It has the right writer (application event emitter) and append-only guard, but its current owner/lifetime fails durability: a Flux-owned Deployment has no PVC, so a Pod recreate loses the relation. **Runner-up: Pod metadata.** It loses because `flux-operator` owns its live managed fields and because the record lasts only until Pod replacement. If the reconciler reverts the label five minutes from now, neither the dashboard nor SuperCred reader can assert containment; the audit relation can assert it only while the disposable Pod survives.

## PostgreSQL durability — resolved premise

**Finding: the requested StatefulSet/PVC premise is false on kind-osramp, which is more severe than a Flux-owned PVC.** The live database is a Flux-owned `Deployment`, not a `StatefulSet`; there is no database PVC. Therefore: a normal Flux reconcile that does not replace the Pod leaves `public.audit_events` present; a kustomize-controller prune of `Deployment/postgresql` deletes its Pod and loses history; a PostgreSQL StatefulSet recreate is inapplicable because no StatefulSet exists; the equivalent actual Deployment Pod recreate loses history. This is the same persistence failure shape as the original bug and blocks claiming durable containment evidence.

```console
$ kubectl -n inf-signalloom get statefulset postgresql
Error from server (NotFound): statefulsets.apps "postgresql" not found
$ kubectl -n inf-signalloom get pvc
No resources found in inf-signalloom namespace.
$ kubectl -n inf-signalloom get deployment postgresql -o jsonpath='{.metadata.managedFields[*].manager}{"\n"}{.spec.template.spec.volumes}{"\n"}'
kustomize-controller kube-controller-manager
[{"configMap":{"defaultMode":420,"name":"discovery-portal-bootstrap"},"name":"init"}]
$ kubectl -n inf-signalloom get kustomization infra-controllers -o custom-columns='NAME:.metadata.name,INTERVAL:.spec.interval,PRUNE:.spec.prune,APPLIED:.status.lastAppliedRevision,ATTEMPTED:.status.lastAttemptedRevision'
NAME                INTERVAL   PRUNE   APPLIED                                                                          ATTEMPTED
infra-controllers   30m        true    latest@sha256:542288d846cf69fa94ab5b3fe48776ec774c3b12172beaf49bcb1797c838cf98   latest@sha256:542288d846cf69fa94ab5b3fe48776ec774c3b12172beaf49bcb1797c838cf98
```

## Live ownership evidence

```console
$ kubectl -n fe-signalloom-agents get pod agent-sir-lancelot -o jsonpath='{.metadata.managedFields[*].manager}{"\n"}'
flux-operator kubelet
$ kubectl -n inf-signalloom get deployment postgresql -o jsonpath='{.metadata.managedFields[*].manager}{"\n"}'
kustomize-controller kube-controller-manager
```

The agent result falsifies the card premise that this live Pod names `kustomize-controller`: it names `flux-operator` and `kubelet`. The ResourceSet itself names `kustomize-controller` and `flux-operator`; that does not transfer the former manager to the materialized Pod. PostgreSQL table data has no Kubernetes `managedFields`; its hosting Deployment output above is the applicable Kubernetes ownership evidence.

## Shipped ignore block

```yaml
ignore:
  - target:
      kind: Pod
      labelSelector: signalloom.ai/agent=true
    paths:
      - /metadata/labels/signalloom.ai~1state
      - /metadata/labels/signalloom.ai~1stun-request
      - /metadata/annotations/signalloom.ai~1stunned-at
      - /metadata/annotations/signalloom.ai~1stun-reason
```

This `Kustomization` ignore block covers only matching Pods reconciled by that Kustomization. It does not cover ResourceSet-managed objects, PostgreSQL, Events, OpenBao, shell output, or dashboard memory. The card contract listed three pointers; the stored repository version now contains the later additive `stun-request` pointer as well.

## Append-only trigger evidence

```sql
CREATE TRIGGER audit_events_append_only
  BEFORE UPDATE OR DELETE OR TRUNCATE ON public.audit_events
  FOR EACH STATEMENT
  EXECUTE FUNCTION public.audit_events_reject_mutation();

ALTER TABLE public.audit_events
  ENABLE ALWAYS TRIGGER audit_events_append_only;
```

Migration `030_audit_events_append_only.sql` records why `REVOKE` would be decoration: the application connects as table owner `signalloom` and is a superuser. Migration `011_agent_stunned_event_type.sql` admits `agent.stunned`. The trigger prevents ordinary rewrite statements but cannot make the underlying non-persistent Pod durable.

## Event TTL and reconcile intervals

```console
$ kubectl -n kube-system get pod -l component=kube-apiserver -o jsonpath='{.items[0].spec.containers[0].command}'
["kube-apiserver", ..., "--runtime-config="]
```

The running command has no explicit `--event-ttl`; this capture cannot prove an effective TTL value, so Event lifetimes remain **UNVERIFIED** rather than being reported as an assumed upstream default. Measured reconcile intervals are ResourceSets `signalloom-infra=5m` and `signalloom-apps=5m`; Kustomizations `inf-signalloom/infra-controllers=30m, prune=true` and `inf-signalloom/infra-configs=30m, prune=true`. For the latter two, `lastAppliedRevision` equals `lastAttemptedRevision` in the pasted PostgreSQL evidence, so that observed state was actually applied.

## Falsifiable reconcile proof

The required source publication and reconcile were executed. The previously applied tenants revision was `latest@sha256:c261a27bf58dd9b1ede0cec3ea93ee1db9f6af5f2f0335a14f62fb85f33a219f`; after `./scripts/push-local.sh` and `flux reconcile kustomization tenants -n flux-system --with-source`, it advanced and applied:

```console
$ kubectl -n flux-system get kustomization tenants -o custom-columns='NAME:.metadata.name,APPLIED:.status.lastAppliedRevision,ATTEMPTED:.status.lastAttemptedRevision,READY:.status.conditions[?(@.type=="Ready")].status'
NAME      APPLIED                                                                          ATTEMPTED                                                                        READY
tenants   latest@sha256:17cd3f6764100155a16f0a52db31bd95dc32111e1bac76a64815a0821f58e47c   latest@sha256:17cd3f6764100155a16f0a52db31bd95dc32111e1bac76a64815a0821f58e47c   True
$ kubectl -n inf-bao exec deployment/openbao -- sh -c 'BAO_ADDR=http://127.0.0.1:8200 bao status'
Storage Type    inmem
Sealed          false
```

This proves an apply, rather than a failed reconcile, and proves the OpenBao runtime remained queryable after it. It does **not** upgrade revocation into containment evidence: OpenBao remains enforcement and its measured in-memory storage has a Pod-restart lifetime.

## Traps for P6-1 and P6-2

- **ResourceSet has no ignore field.** The Pod-path survival mechanism belongs to the generated Kustomization, not the ResourceSet; do not assume a ResourceSet-managed object can use it.
- **Events aggregate.** Repeated observations update one Event series and its `count`; they do not necessarily produce N Event objects.
- **`drift` is not a detector contract.** A scoped search found occurrences in scripts/manifests, so the prompt claim that it appears nowhere there is false on this revision; P6-2 must use a concrete emitted signature rather than word search. Documentation has 43 matching files and `olly-replica` has 33.
- **Configured events are ephemeral.** The card contract records a historical measurement of 36 configured occurrences on one agent Pod without an alert. At this capture, `agent-sir-lancelot` has zero unexpired configured Events, demonstrating that the Event store cannot preserve that evidence.
- **Monitoring is not assumed.** `kubectl get deployment -A -l app.kubernetes.io/name=kube-prometheus-stack` returned `No resources found`; P6-2 has no measured kube-prometheus-stack sink on this cluster.

## Reader boundaries

`scripts/supercred-evidence.sh:424` uses `grep -qE 'state=stunned|stunned-at=[0-9]'` over a fresh Pod query. It holds no independent record, and after reversion it cannot distinguish `never stunned` from `stunned then reverted`. The dashboard projection and `stunActivity.test.ts` similarly read/projection-test live state. OpenBao revocation is enforcement, not evidence: it may prove credentials were revoked but not that a containment record was durably emitted.
