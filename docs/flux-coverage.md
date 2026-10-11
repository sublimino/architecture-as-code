# Flux management: which workloads GitOps actually reconciles

Audited 2026-10-11 against base commit `19d7bf03`.

Short answer: no, not everything runs with Flux CD.

## What "managed" means here, and what it does not

This measures one thing: whether a manifest is **managed by Flux** — reachable
from a fleet overlay, so a rebuild replays it. It says **nothing** about whether
a workload is secure, hardened, or compliant. An unmanaged workload is not an
insecure one, and a Flux-managed one is not a hardened one.

This page and the gate said "covered" and "uncovered" until 2026-10-11. In a
repository that also carries a compliance engine, a risk pack and a policy-scan
API, "coverage" is read as *security* coverage, and the two questions have
different owners and different remediations — a GitOps gap is fixed by wiring a
Kustomization, a hardening gap by changing a pod spec. The words are now
"managed" and "unmanaged" throughout, including the JSON keys
(`managed_docs`, `unmanaged_docs`, `undeclared_unmanaged`) and the gate's
`UNDECLARED UNMANAGED WORKLOAD` line. The metric, the exception semantics and
every exit code are unchanged. The file names keep "coverage" so existing
references resolve.

## How this was established

Two independent views, which agree.

**Live.** `~/.kube/config` is unreadable under the sandbox. That is not evidence
of an empty estate. A blocked read and an empty world produce identical output.
Note also that `test -r ~/.kube/config` returns 0 while `open()` fails, because
`access()` and the real read are answered by different layers. Ground truth came
from channels the sandbox cannot blank. `docker ps` lists
`osramp-control-plane`. `ps -eo args` shows two live `kube-apiserver`
processes. `kind get clusters` lists `osramp` and `signalloom-hub`. A usable
kubeconfig was then recovered with `kind get kubeconfig --name osramp`.

**Static.** `scripts/flux-workload-coverage.py` walks top-down from each cluster
overlay. It is enforced by `test/flux-workload-coverage.bats`.

The live cluster was built from a commit well ahead of this base. Live is the
authority on what Flux owns. The static walk is the authority on this tree.

## The two sets

Set A is every workload manifest the repository declares. Set B is every
directory a Flux object actually reconciles.

| Measure | Count |
| --- | --- |
| Set A, workload documents in delivery roots | 105 |
| Set B, Flux Kustomization roots | 56 |
| Files reached from those roots | 266 |
| Documents managed by Flux | 79 |
| Unmanaged documents, A minus B | 26 |
| Declared exceptions in the register | 25 |
| Of those, admitted gaps | 10 |

A second count tells the same story from the other end. Of 115
`kustomization.yaml` files in the tree, 34 are reachable from no Flux object.

Run `scripts/flux-workload-coverage.py --list-sets` to print both sets in full.

## Why the chain is four hops

Delivery is artifact based, not git based. Every source is an `OCIRepository`.

```
workload yaml
  <- kustomization.yaml listing it, possibly transitively
  <- Flux Kustomization CR whose spec.path lands on that directory
  <- OCIRepository whose artifact is built from the directory above it
  <- the fleet overlay the cluster root Kustomization points at
```

Break any hop and the manifest becomes decoration. It still reads like
production configuration.

Two traps caught during the walk. First, `${ENVIRONMENT}` comes from each
cluster's `flux-runtime-info` ConfigMap, never from the directory name.
`prod-eu` and `prod-us` both mean `production`. A resolver that assumes
otherwise invents 16 dangling paths. Test 7 pins that. Second, the artifact to
directory map lives only in `scripts/push-local.sh`. A `ResourceSet` may
reference an artifact that nothing publishes. Test 9 pins that.

## Live workloads with no Flux provenance

Discriminator: no `kustomize.toolkit.fluxcd.io/name`, no
`helm.toolkit.fluxcd.io/name`, no `resourceset.fluxcd.io/name`, no owner
reference. Nothing in GitOps would recreate these after a rebuild.

| Live workload | Applied by | Verdict |
| --- | --- | --- |
| `fe-k8s-afm/afm-platform`, `afm-cluster-import` | `scripts/k8s-afm.sh` | drift |
| `inf-signalloom/cardvault` | `scripts/supercred-demo.sh` | drift |
| `inf-signalloom/policy-engine` | demo script | drift, a second copy |
| `kube-system/sldc-bridge-dns` | SLDC bridge bring-up | drift |
| `kagent/*`, four deployments | `scripts/kagent-infra.sh`, Helm | drift |
| `fe-signalloom-agents/agent-nono-kusari` | demo script | drift |
| `fe-signalloom-agents/netassert-*-fixture` | test fixture left resident | drift |
| `knative-serving/*`, `knative-eventing/*`, `kourier-system/*` | `make swarm-knative-up` | bootstrap, undeclared |
| `registry/zot` | `make registry` | bootstrap |
| `default/probe` | `scripts/cluster.sh` | bootstrap |
| `flux-system` controllers | `FluxInstance` | correct |
| `kube-system` and `local-path-storage` core | kind | correct |

The Knative row is the interesting one. Flux genuinely cannot install it. The
`swarm-knative-up` recipe says so in its own comments, and it patches three CRD
schemas to let Flux server-side dry-run succeed afterwards. That reasoning was
never recorded anywhere a rebuild would read. It is now a declared exception.

## The repository already knows

`demo-signalloom-fleet-up` prints a warning before it hand-applies the Fleet
Manager. The warning says Flux reverts it on the next reconcile, and that the
cross-namespace RBAC is not applied. That is the right instinct. It was applied
to one target out of roughly thirty.

## Named gap: policy-engine ships on a mutable tag

Of 101 image references in Flux-reached manifests, four are pinned. Two of those
are upstream digests. Only `signal-ingest` and `signalloom-warden` use the
content-derived `src-<hash>` tag. The remaining 97 float on `local`, `latest`,
`dev`, or `${ARTIFACT_TAG}`.

One of those 97 matters more than the rest. `d2-signalloom/apps/policy-engine`
imports `d2-signalloom/pkg/obscel`. That is the shared package named in the
standing re-pin rule. Its Deployment is Flux-reconciled, confirmed live by the
`apps` label, and it runs `policy-engine:local`.

The asymmetry is the dangerous part. A change to `pkg/obscel` forces a re-pin of
the `signal-ingest` tag. Forget it and
`TestReconciledManifestRunsTheImageBuiltFromThisSource` goes red. The same
change ships a stale `policy-engine` in silence, because no equivalent exists.

What it needs, as a separate card:

- `scripts/policy-engine-image-tag.sh`, mirroring `scripts/sentinel-image-tag.sh`
- the dirty-input refusal from `scripts/lib/source-id.sh`
- a reconciled-manifest provenance test, mirroring the `signal-ingest` one
- the tag written into `d2-signalloom/apps/policy-engine/base/deployment.yaml`

Not built here. W1 holds that tree.

## What was deliberately not changed

No manifest that Flux reconciles was touched. `kind-osramp` is shared, other
sessions are active, and a manifest edit lands on the estate at the next sync.
Adding the two single-file `inf-bao` gaps alone would create a Job and a CronJob
in a live namespace. Those gaps are recorded in the register as class `gap` and
are owner decisions.

## Register and gate

`docs/flux-coverage-exceptions.yaml` holds every exception with a class, a
reason, and the thing that applies it. Classes are `bootstrap`,
`out-of-band-lab`, `runtime-template`, `test-fixture`, and `gap`.

The register cannot be used as a waiver. The gate fails on an undeclared
unmanaged workload. It also fails on a stale entry, meaning one whose file is
gone or whose manifest is now genuinely reconciled. An entry with no reason
fails as malformed.

| Mutation | Expected |
| --- | --- |
| New workload slice, no Flux object names it | fail, undeclared |
| Delete an exception for a gap that still exists | fail, undeclared |
| Exception for a path that no longer exists | fail, stale |
| Exception for a manifest Flux does reconcile | fail, stale |
| Exception with no reason | fail, malformed |
| Resolver asked for `prod-eu` | returns `production` |
| Any Kustomization path absent from the tree | fail, dangling |
| OCI artifact with no source directory | fail, unmapped |
