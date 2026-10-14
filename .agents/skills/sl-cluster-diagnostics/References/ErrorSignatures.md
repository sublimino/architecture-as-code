# Cataloged Error Signatures & Remediation Matrix

This document catalogs common cluster failure signatures encountered in `osramp-demo` and Signal Loom, their root causes, and standard remediations.

---

## Failure Matrix

| Signature ID | Symptom / Log Signature | Root Cause | Verified Remediation |
| :--- | :--- | :--- | :--- |
| `CERT_MANAGER_ACME_FINALIZER_LOOP` | `error cleaning up challenge: error getting cloudflare secret: secrets "cloudflare-api-token" not found` | Leaked test ACME Challenge objects in `cert-manager` namespace have finalizers waiting on non-existent cloudflare credentials. | Run `make clean-test-artifacts` or `./scripts/clean-test-artifacts.sh` to strip finalizers and purge leaked challenges. |
| `DASHBOARD_OIDC_REDIRECT_STORM` | `GET /dex/auth?client_id=signalloom-dashboard... 302` looping at 100+ req/s | SPA component re-rendering on expired token without single-flight lock or checking `isAuthenticated`. | Rebuild dashboard image with single-flight auth lock in `oidc.tsx` and run `./scripts/build-sign-dashboard.sh`. |
| `WARDEN_CORRELATOR_HOLD` | `{"event":"thaw_refused_correlator_hold","pod":"...","reason":"sys_enter_openat /proc/sys/kernel/cap_last_cap"}` | eBPF warden detected security-sensitive kernel namespace traversal and placed workload under correlator hold. | Inspect pod behavior and verify if agent was intentionally stunned via `sl-containment-guard` or if probe should be allowed. |
| `OPENBAO_UNSEEDED_AGENT_SECRETS` | `[WARN] agent: (view) vault.read(secret/data/agents/...): no secret exists` | `openbao-agent` sidecars polling for credentials before seed scripts have completed. | Run `scripts/swarm-seed-secrets.sh` to populate Vault secret paths. |
| `CONTAINER_IMAGE_PULL_FAILURE` | `ImagePullBackOff` or `ErrImagePull` on pod status | Kind node cannot find local image in docker daemon or Zot registry cache. | Run `CLUSTER_NAME=osramp ./scripts/kind-load-verified.sh <image>:dev` or rebuild slice with `make demo-<slice>-up`. |
| `POD_CRASH_LOOP` | `CrashLoopBackOff` or non-zero container exit code | Application panic, missing environment variable, or failed database connection. | Run `kubectl logs --previous -n <ns> <pod>` to inspect crash stack trace before container restart. |
| `ETCD_SLOW_REQUEST_TRACE` | `etcd {"level":"warn",...,"msg":"request stats","time spent":"...ms"}` | etcd linearized raft read latency under heavy concurrent I/O. | Normal during cluster bootstrap or large image loads. If persistent, check host disk I/O with `iostat`. |
