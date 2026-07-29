---
task: Review Zot registry manifest cache security contexts
slug: 20260727-175000_zot-registry-manifest-security-review
effort: standard
phase: complete
progress: 8/8
mode: interactive
started: 2026-07-27T17:50:00+01:00
updated: 2026-07-27T17:50:08+01:00
---

## Context

Read-only security review of the Zot local registry manifest and its cache-preparation execution path. The review determines whether the current workload and container security contexts enforce least privilege, and names any regression required by an evidence-backed proposed change. No repository files, manifests, or runtime state may be edited.

### Risks

- Kubernetes-level defaults can mask a missing container-level security control.
- Cache ownership requirements can justify a non-root user without requiring root.
- An init container can differ materially from the main Zot workload.

## Criteria

- [x] ISC-1: Zot manifest location is identified from repository evidence.
- [x] ISC-2: Cache-preparation execution path is identified from repository evidence.
- [x] ISC-3: Registry container effective user privileges are evidenced.
- [x] ISC-4: Cache-preparation container effective user privileges are evidenced.
- [x] ISC-5: Privilege-escalation controls are evidenced for each workload container.
- [x] ISC-6: Linux capability controls are evidenced for each workload container.
- [x] ISC-7: Writable filesystem requirements are compared against declared mounts.
- [x] ISC-8: Proposed least-privilege regression is explicitly named or ruled out.

## Decisions

- Review scope is limited to repository configuration and executable cache-preparation definitions.
- No edits, deployments, image pulls, or runtime probes are permitted.
- Inspect manifest declarations, referenced scripts, and relevant tests; report only evidenced conclusions.

## Verification

- `d2-osramp-fleet/local/zot.yaml` defines the Zot Deployment and `prepare-data` init container.
- `scripts/create-kind-cluster.sh` creates the cache, maps it through Kind, and sets its mode.
- Both containers set UID and GID 65532, use `runAsNonRoot`, disable privilege escalation, and drop all Linux capabilities.
- Zot alone declares a read-only root filesystem; its required writable data path is the mounted `/var/lib/zot` hostPath.
- The init container only tests directory existence and writability on that mounted path.
- The cache-preparation script sets `chmod 0777`, making the cache world-writable; `test/zot-cache.bats` asserts mode 777.
- This is a least-privilege regression relative to a UID-owned, mode-restricted cache, despite the non-root pod contexts.
- `bash -n scripts/create-kind-cluster.sh` and `git diff --check` passed without output.
- No diff exists from HEAD for the manifest or cache-preparation script.
