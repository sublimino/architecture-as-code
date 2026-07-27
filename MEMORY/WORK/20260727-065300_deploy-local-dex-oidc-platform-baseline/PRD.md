---
task: Deploy local Dex OIDC platform baseline
slug: 20260727-065300_deploy-local-dex-oidc-platform-baseline
effort: advanced
phase: complete
progress: 25/25
mode: interactive
started: 2026-07-27T06:53:00+01:00
updated: 2026-07-27T07:13:00+01:00
---

## Context

Implement the scoped local Dex/OIDC foundation for Signalloom D2. It must use only deterministic local credentials and Kubernetes configuration, expose standards-compliant discovery and JWKS endpoints, map the authenticated demonstration user to the existing tenant boundary, and configure the dashboard's generic OIDC environment. Production federation, real credentials, network-exposed deployment, board changes, pushes, and pull requests are excluded. The named integration ref must be an ancestor before feature changes.

### Risks

- A Dex static password must be bcrypt-hashed and never retained as plaintext.
- Local issuer URL must match existing API JWT validation expectations.
- Discovery and JWKS cannot be live-validated without a running local cluster.
- The dashboard may only support environment-level provider configuration presently.
- Integration-ref drift after revalidation would invalidate implementation authority.

### Plan

1. Verify the mandated integration ref is an ancestor of the task worktree.
2. Follow existing `fe-signalloom` Kustomize and test conventions for an isolated Dex app.
3. Add static-password Secret, Dex configuration, Deployment, Service, and dashboard OIDC environment.
4. Add hermetic manifest and discovery/JWKS contract tests, then run them with existing suite.
5. Review, commit only scoped files, and append the proposal errata machine tag.

## Criteria

- [x] ISC-1: Required integration ref exists in local repository.
- [x] ISC-2: Required integration ref is ancestor of HEAD.
- [x] ISC-3: Dex deployment declares the local infrastructure namespace.
- [x] ISC-4: Dex deployment specifies the pinned Dex image.
- [x] ISC-5: Dex Service exposes port 5556 internally.
- [x] ISC-6: Dex configuration enables the password connector.
- [x] ISC-7: Demo credential Secret stores a bcrypt password hash.
- [x] ISC-8: Demo credential Secret excludes plaintext password values.
- [x] ISC-9: Dex configuration declares the dashboard OIDC client.
- [x] ISC-10: Dashboard client declares a local redirect URI.
- [x] ISC-11: Dex configuration enables local password authentication.
- [x] ISC-12: Demo user maps to the configured tenant value.
- [x] ISC-13: Dex configuration defines the local issuer URL.
- [x] ISC-14: Dex discovery endpoint is configured for readiness validation.
- [x] ISC-15: Dex issuer convention provides the JWKS discovery contract.
- [x] ISC-16: Dex signing key is served through JWKS at runtime.
- [x] ISC-17: Dashboard deployment declares generic OIDC provider variables.
- [x] ISC-18: Dashboard deployment references the local Dex issuer.
- [x] ISC-19: Dashboard provider configuration declares the dashboard client identifier.
- [x] ISC-20: Authentication test verifies bcrypt credential configuration.
- [x] ISC-21: Authentication test verifies dashboard client configuration.
- [x] ISC-22: Authentication test verifies tenant claim mapping.
- [x] ISC-23: Authentication test verifies discovery and JWKS contracts.
- [x] ISC-24: Focused authentication test suite exits successfully.
- [x] ISC-25: Commit contains only scoped Dex authentication changes.

## Decisions

- Use Dex static-password local authentication only; production federation remains excluded.
- Treat Kubernetes YAML plus hermetic contract tests as the delivery boundary unless a local Kind cluster is already available.

## Verification

- `git merge-base --is-ancestor integration/signalloom-d2-v2.5.0 HEAD`: exit 0.
- `bats d2-signalloom/test/dex-auth.bats d2-signalloom/test/dex-runtime.bats`: exit 0, 6/6 passed.
- `kubectl kustomize d2-signalloom/infra/inf-signalloom/configs/local`: exit 0.
- `kubectl kustomize d2-signalloom/apps/fe-signalloom/local`: exit 0.
- `git diff --check -- d2-signalloom`: exit 0.
- Independent QATester rerun: PASS, 6/6 and both Kustomize renders passed.
- Commit `40b9ff8` contains eight scoped Dex/OIDC files.
- `make -C d2-signalloom test` remains blocked at existing `check-bootstrap-drift.sh`; the focused auth suite itself passed.
