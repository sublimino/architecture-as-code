---
task: Generalize shared namespace cleanup across cluster-down scripts
slug: 20260726-233200_diagnose-osramp-down-namespace-cleanup
effort: standard
phase: complete
progress: 8/8
mode: interactive
started: 2026-07-26T23:32:00+01:00
updated: 2026-07-26T23:42:00+01:00
---

## Context

The original OSRAMP cleanup duplicated fragile ResourceSet and namespace-finalizer
logic. The implementation now extracts that lifecycle into a parameterized helper
shared by OSRAMP, Olly, and Signal Loom wrappers. Make targets continue to expose
the product-specific commands while documenting the shared cleanup path.

### Risks

- The script currently suppresses deletion and patch failures with `|| true`.
- It only targets a narrow set of namespaced resource kinds.
- A namespace can be Terminating while `kubectl delete` reports success.
- Flux may recreate workloads if the wrong ResourceSet is patched.
- The live cluster may differ from the script's hard-coded `apps` contract.

## Criteria

- [x] ISC-1: Root cause is identified from script and cluster evidence
- [x] ISC-2: ResourceSet reconciliation is stopped before namespace deletion
- [x] ISC-3: Namespace-owned workload finalizers are removed before deletion
- [x] ISC-4: Namespace deletion failures remain visible to the operator
- [x] ISC-5: Stuck namespaces receive bounded repeated finalization attempts
- [x] ISC-6: Script preserves infrastructure namespaces and restoration inputs
- [x] ISC-7: Shell syntax and relevant script checks pass after patching
- [x] ISC-8: Cluster verification confirms targeted namespaces are absent

## Decisions

- Keep the existing ResourceSet patch and restore-file contract.
- Add generic namespaced finalizer cleanup because generated kinds vary.
- Retry namespace force-finalization with bounded, visible failures.
- Use `xargs -r` so empty resource lists do not invoke invalid patches.
- Parameterize the shared helper by ResourceSet, restore file, and namespaces.

## Verification

- Root cause evidence: `apps.spec.inputs=[]` produces `BuildFailed` because the
  ResourceSet template requires `inputs.tenant`; its old inventory therefore is
  not pruned automatically.
- `scripts/resourceset-down.sh` now owns shared cleanup behavior.
- Product wrappers invoke the helper with their existing ResourceSet contracts.
- `bash -n`, ShellCheck, `git diff --check`, and Make dry-runs passed.
- `./scripts/osramp-down.sh` ran successfully against the current cluster.
- Cluster verification returned NotFound for `frontend` and `backend`.
- `inf-bao`, `inf-signalloom`, and `monitoring` remained Active.

Learning: extracting the shared lifecycle after diagnosing the live failure kept
the patch surgical while preventing three scripts from drifting independently.
The next improvement would be a fake-kubectl regression harness for finalizer
and force-finalization branches; live validation alone cannot exercise failures
without risking a real namespace.
