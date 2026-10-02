# SLAAT-P1-3 — SPIFFE Identity & OpenBao Privilege Escalation Dossier

**Mission:** SLAAT (Signal Loom Autonomous Adversarial Testing), Phase 1 — Whole-System Adversarial Attack & Boundary Probing
**Card:** `SLAAT-P1-3` — SPIFFE Identity & OpenBao JWT Privilege Escalation Probing
**Target:** `d2-agent-trust` (SPIRE registration entries, OpenBao role intent), `d2-signalloom/infra/inf-bao` (live SPIRE server/agent + OpenBao deployment) — live `kind-osramp` cluster
**Method:** live, read-only adversarial probing against the real deployed trust domain (`signalloom.demo`). Every probe is either a self-cleaning ephemeral pod (`kubectl run --rm`) or a `bao`/`kubectl exec` read; nothing in this card edits a SPIRE registration entry, an OpenBao role/policy, or any `d2-agent-trust`/`inf-bao` manifest.

## Summary

34 live adversarial probes executed against the real `kind-osramp` cluster's SPIRE server/agent and OpenBao deployment. Zero unauthorized role logins succeeded, zero cross-tenant KV reads succeeded, zero forged-identity attestations succeeded, and signature/`alg:none` forgery was rejected in every attempt — the fail-closed boundaries the mission's Shared Patterns require all held under direct attack. The genuine findings are not bypasses: two live OpenBao JWT roles issue tokens with a 32-day lifetime instead of the mission's stated 5-minute hard cap (F1, the headline finding), one role's templating mechanism has never actually worked for any of its 18 target agents due to a missing `bound_claims_type` (F2 — a fail-closed correctness bug, not an exploitable gap), and two of four registered tenant identities have no OpenBao role bound to them at all (F3 — under-provisioning, the inverse of a privilege-escalation risk).

## Scope and method

Three live probe harnesses, all idempotent and self-cleaning:

| Script | Focus |
| --- | --- |
| `scripts/probe-spiffe-privilege-escalation.sh` | SPIRE Workload API attestation (forged identity), OpenBao JWT login (audience bypass, cross-identity bypass, bound_claims defects, signature/`alg:none` forgery, KV/admin-surface boundary), and a live TTL sweep of every `auth/jwt/role` |
| `test/spiffe-identity-probes.sh` | SPIRE registration-entry selector audit (weak namespace-only selectors) plus two live attestation attempts: namespace tampering (unregistered SA, co-located) and process impersonation (registered SA, missing required pod-label) |
| `scripts/probe-openbao-acls.sh` | Live OpenBao policy-boundary audit (no cross-tenant/admin-surface wildcard grants) and a delegation-coverage cross-reference between every live SPIRE registration entry and every live OpenBao JWT role |

Each harness is wrapped by a bats suite (`test/spiffe-openbao-adversarial.bats`, `test/openbao-security-probes.bats`) that runs the live script once per file and asserts individual record severities — skip-if-no-cluster, fail-loud-if-cluster-present-but-empty, matching the convention established by `SLAAT-P1-1`'s `adversarial-network-probes.bats`.

**Why live-only, no synthetic SVID forging bypassed SPIRE's own signing.** The card's Approach names "craft synthetic X.509 SVIDs and JWT SVIDs with forged SPIFFE IDs." A SPIRE-issued JWT-SVID is signed by SPIRE's own EC key, published live at `spire-oidc.inf-bao.svc.cluster.local:8008/keys` and pulled by OpenBao's `jwks_url`; there is no way to forge a `sub` claim inside a *validly signed* SVID without the SPIRE server's private key (explicitly out of scope — "SPIRE server private key compromise" is a hard STOP blocker on this card). The adversarially meaningful version of "forged SPIFFE ID" is therefore: (a) can an attacker get SPIRE to *issue* an SVID for an identity it should not have (tested live — denied, see B1), and (b) can an attacker present a token that is *not* validly signed and get OpenBao to accept it anyway (tested live with both a tampered-signature token and a hand-crafted `alg:none` token carrying the exact claims of a real identity — both denied, see B2). Both are the real-world shape of "forged SPIFFE ID" against a system that anchors signature verification to the issuer's own live key material.

## Findings

### F1 — `signalloom-cardvault-agent` and `signalloom-fe-signalloom` issue 768-hour tokens, not the mission's 5-minute hard cap (CRITICAL)

Both roles define no `token_ttl`/`token_max_ttl`, so they inherit the `auth/jwt` mount's `default_lease_ttl=768h` (confirmed: `bao read -format=json sys/auth/jwt/tune` → `default_lease_ttl=2764800`). A live login against `signalloom-cardvault-agent` with a real, correctly-audienced JWT-SVID (minted via the Workload API for the actually-running `agent-cardvault` pod) returned `token_duration=768h`, `token_renewable=true`, `token_type=default` (a renewable service token, not the short-lived `batch` type used elsewhere). This directly contradicts the mission's stated invariant: "Maximum token TTL for agent credentials is hard-capped at 5 minutes to prevent replay vulnerabilities."

The architecture demonstrably knows how to do this correctly — the sibling `agent-trust-planner`/`agent-trust-triage`/`signalloom-agent-generic` roles all explicitly set `token_ttl=5m`, `token_max_ttl=5m`, `token_type=batch` (confirmed live via `bao read`). These two roles are a regression, not a design limitation.

**Blast radius is partially contained.** Live probing (`SPIFFE-4` through `SPIFFE-9`) confirmed the issued token's policy still correctly restricts it to its own KV path and denies cross-tenant reads and every admin-surface read attempted (`sys/mounts`, its own role definition). This is a replay-window/revocation-latency exposure — a captured token stays live for up to 32 days and is renewable — not an independent privilege-escalation path.

**Severity:** CRITICAL. **Remediation:** add `token_ttl=5m`, `token_max_ttl=5m`, `token_type=batch` to both roles, matching the `agent-trust-planner`/`triage` pattern. **Phase:** `SLAAT-P2-3`.

### F2 — `signalloom-agent-generic`'s `bound_claims` glob has never worked for any of its 18 target agents (MEDIUM, fails closed)

The role's `bound_claims` is `{"sub": "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/*"}` with no `bound_claims_type` field, so OpenBao defaults to `bound_claims_type=string` — the trailing `*` is compared as a *literal* character, never a wildcard. Live-confirmed with a real, correctly-registered, correctly-audienced SVID (`agent-cardvault`, `aud=openbao-supercredential`): the login still failed at the claim-match step with `claim "sub" does not match any associated bound claim values`, proving no real SPIFFE `sub` can ever satisfy a literal trailing asterisk.

This is the *exact* bug class already found and fixed elsewhere in this same codebase: `openbao-supercred-bootstrap.yaml`'s own comment block (documenting defect "PF-3") explains that `bound_claims_type: "glob"` is load-bearing for precisely this shape, and that the fix was applied to `signalloom-cardvault-agent` and the `osramp.local` `agent-cardvault` role — but it was never back-ported to `signalloom-agent-generic`. Net effect: the fleet-wide "one role scales to every agent via identity templating" mechanism this file's own comments describe has never functioned for any of the 18 registered `fe-signalloom-agents/sa/*` identities (`cpai-engineer`, `swarm-governor`, every `kagent-*` analyst, etc.).

This fails **closed** — it is a correctness/availability defect sitting next to a would-be security control, not an exploitable bypass.

**Severity:** MEDIUM (fails closed). **Remediation:** add `"bound_claims_type": "glob"` to the role write in `openbao-agent-generic-role.yaml`. **Phase:** `SLAAT-P2-3`.

### F3 — Two of four registered agent-trust tenant identities have no OpenBao JWT role at all (LOW, delegation gap)

`spire-registrations.v1.json` registers four `agent-trust` identities: `acme/payments/planner`, `acme/payments/triage`, `acme/risk/risk-reader`, `northstar/investigations/investigator`. All four have live SPIRE registration entries on the cluster today. `openbao-role-intent.sh` only provisions a policy and roles for the `acme/payments` pair — `risk-reader` and `investigator` have valid, attestable SPIFFE identities but no `auth/jwt` role anywhere binds their `sub` claim, so they have no path to an OpenBao credential at all.

This is the *inverse* of a privilege-escalation risk (under-provisioning), but it is precisely the "delegation gap" the card's Objective asks this audit to catalog. The same cross-reference also surfaced four `spiffe://signalloom.demo/ns/eap-*/sa/tenant-app` identities in the same unmatched state; those belong to the unrelated EAPR mission (see `EAPR-P2-1`), which provisions its own non-OpenBao authentication path, and are noted for completeness only — `test/openbao-security-probes.bats`'s "delegation gap scope note" test documents this boundary explicitly so the distinction survives into CI, rather than quietly disappearing from a future reader's attention.

**Severity:** LOW. **Remediation:** extend `openbao-role-intent.sh` (or its equivalent live bootstrap path) to provision a policy + role pair for `acme/risk/risk-reader` and `northstar/investigations/investigator`. **Phase:** `SLAAT-P2-3`.

### F4 — SPIRE agent runs with `insecure_bootstrap=true` and `skip_kubelet_verification=true` (LOW, demo-appropriate)

`spire-openbao-config.yaml`'s `spire-agent-config` ConfigMap sets both flags. `insecure_bootstrap=true` means the agent does not verify the SPIRE server's TLS certificate on its first join; `skip_kubelet_verification=true` means the k8s `WorkloadAttestor` does not verify the kubelet's TLS certificate when querying pod metadata for attestation. Neither was exploited live in this probe — both require a network position (node-to-server or agent-to-kubelet MITM) this engagement's scope does not grant — and both are named, well-understood SPIRE hardening knobs appropriate for a local `kind` demo.

**Severity:** LOW (hardening item, not an active finding). **Remediation:** before any non-local deployment, set `insecure_bootstrap=false` with a pinned server bundle, and `skip_kubelet_verification=false` with `kubelet_ca_path` configured. **Phase:** `SLAAT-P2-3`.

### F5 — `agent-cardvault`'s Workload API socket uses a raw `hostPath` mount instead of the documented `spiffe-csi-driver` volume (INFO)

`d2-agent-trust/AGENTS.md` documents `spiffe-csi-driver` as the standard mechanism for wiring the Workload API socket into a pod. The live `agent-cardvault` Deployment instead mounts `/run/spire/sockets` as a plain `hostPath` `Directory` volume. Because SPIRE's `k8s` `WorkloadAttestor` identifies the calling workload by a PID→container→pod lookup (not by how the socket was mounted), this alone does not let the pod obtain any identity other than its own attested one — confirmed live (`IDENT-2`, `IDENT-3`: both co-location and partial-selector-match attempts were denied). It does widen the PodSecurity/admission exposure surface relative to the CSI-scoped design the documentation describes.

**Severity:** INFO. **Remediation:** migrate `agent-cardvault`'s Workload API mount to the `spiffe-csi-driver` ephemeral CSI volume for consistency. **Phase:** `SLAAT-P2-3`.

### F6 — Static root token (`signalloom-demo-root-token`) hardcoded across multiple live ConfigMaps/Jobs (INFO, pre-existing accepted convention)

The literal string is used as `BAO_TOKEN` in at least four bootstrap Jobs. This is a known, pre-existing, cluster-wide-blast-radius credential with no rotation or lease, explicitly named as a demo convention. Recorded per the Objective's request to document all policy risks; should be the first thing closed before any path toward a shared or production environment.

**Severity:** INFO. **Remediation:** replace with a short-lived bootstrap credential scoped to setup-time only. **Phase:** `SLAAT-P2-3`.

## Verified boundaries (the attack surface that held)

- **B1 — SPIRE correctly denies attestation to unregistered and partially-matching workloads.** An unregistered ServiceAccount co-located in the trusted `fe-signalloom-agents` namespace with the fleet's own required pod-label was denied an SVID (`rpc error: code = PermissionDenied desc = no identity issued`). A *registered* ServiceAccount missing only the required pod-label was also denied, confirming registration-entry selectors are evaluated as AND, not OR. No live registration entry relies on a namespace-only selector.
- **B2 — OpenBao's JWT auth backend correctly rejects cross-identity, cross-audience, tampered-signature, and `alg:none`-forged tokens.** A valid SVID for one identity was rejected by a role bound to a different `sub` ("invalid subject (sub) claim"); a wrong-audience SVID was rejected on audience grounds; a tampered-signature token and a hand-crafted `alg:none` token carrying a real identity's exact claims were both rejected by signature verification, which is anchored to SPIRE's live JWKS endpoint, not a static or offline key set.
- **B3 — Once authenticated, a token cannot escalate horizontally or vertically.** The token issued to `agent-cardvault` read its own KV path successfully and was denied (403) on every cross-tenant path attempted (`fe-signalloom`'s secret, another agent's templated path, the `agent-trust` `acme/payments` secret) and every admin-surface path attempted (its own role definition, `sys/mounts`). F1's TTL defect is a replay-window exposure, not a privilege-escalation path — this boundary holds regardless.
- **B4 — Every live OpenBao policy is scoped to a single tenant/agent/identity-templated subtree.** No policy grants a bare top-level `kv/data/<x>` catch-all, a cross-tenant wildcard, or any `sys/*`/`auth/*` admin-surface path. `signalloom-agent-templated` correctly uses OpenBao's identity-templating (`{{identity.entity.aliases.auth_jwt.metadata.sub}}`) rather than a static broad path — it simply cannot be exercised today because of F2.

- **B5 — No TLS client-certificate (`cert`) auth method is mounted; the rogue-certificate login vector named in the card's Required Tests does not exist on this deployment.** `bao auth list` shows only `jwt/` and `token/` mounted (confirmed live). A direct `curl --cert <rogue>.pem https://.../v1/auth/cert/login` against the port-forwarded service returns no response at all (`HTTP_STATUS:000` — the listener is plain HTTP, not HTTPS, on this port) — there is no `auth/cert` path to attack. A direct `curl -X POST .../v1/auth/jwt/login` with a forged, unsigned JWT (`alg:none`, garbage signature) returns `400` with `error verifying token signature: failed to verify id token signature`, confirming the earlier `bao write`-based rejection evidence (B2) via the literal HTTP path the card's Required Tests specify.

## Evidence

- `ci-evidence/slaat-p1-3-spiffe-findings.json` — curated findings catalog (this dossier's structured counterpart)
- `ci-evidence/slaat-p1-3-live-probe-records.json` — raw records from `probe-spiffe-privilege-escalation.sh` + `spiffe-identity-probes.sh` (22 records, 4 fail-severity)
- `ci-evidence/slaat-p1-3-acl-audit-evidence.json` — raw records from `probe-openbao-acls.sh` (12 records, 7 fail-severity, of which 6 are distinct delegation gaps)
- `test/spiffe-openbao-adversarial.bats` (16 tests), `test/openbao-security-probes.bats` (8 tests) — both green against the live cluster at the time of this run
