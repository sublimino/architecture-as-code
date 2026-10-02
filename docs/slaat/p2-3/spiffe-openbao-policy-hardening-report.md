# SLAAT-P2-3: SPIFFE Workload API & OpenBao Policy Hardening Report

**Card:** `SLAAT-P2-3` — SPIFFE Workload API & OpenBao Policy Hardening Fixes
**Target:** `d2-signalloom/infra/inf-bao/`, `d2-agent-trust/`
**Method:** live fix against the real `kind-osramp` cluster's OpenBao deployment, applied first via `kubectl exec` to match the declarative manifest edits exactly, then re-verified with the Phase 1 live probe scripts.

## Findings closed

### F1 (CRITICAL) — 768h tokens instead of the 5-minute mission cap

`signalloom-cardvault-agent` (`d2-signalloom/infra/inf-bao/configs/base/openbao-supercred-bootstrap.yaml`) and `signalloom-fe-signalloom` (`d2-signalloom/infra/inf-bao/configs/base/openbao-bootstrap.yaml`) declared no `token_ttl`/`token_max_ttl`, so both inherited the `auth/jwt` mount's `default_lease_ttl=768h`. A live login against either role returned a renewable, 32-day-lived token — a replay-window/revocation-latency exposure, not an independent privilege-escalation path (the issued token's policy still correctly restricted it to its own KV path; see B3 in the P1-3 dossier).

**Fix:** added `token_ttl=5m`, `token_max_ttl=5m`, `token_type=batch` to both role definitions, matching the already-correct `agent-trust-planner`/`agent-trust-triage` pattern in `d2-agent-trust/contracts/openbao-role-intent.sh`.

**Before/after (live, `kind-osramp`):**

| Role | token_ttl | token_max_ttl | token_type |
| --- | --- | --- | --- |
| `signalloom-cardvault-agent` | 0 (→768h effective) → **300** | 0 → **300** | `default` → **`batch`** |
| `signalloom-fe-signalloom` | 0 (→768h effective) → **300** | 0 → **300** | `default` → **`batch`** |

Full before/after role dumps: `docs/slaat/p2-3/before-fix-role-state.json`, `docs/slaat/p2-3/after-fix-role-state.json`.

### F2 (MEDIUM, fails closed) — `bound_claims_type` missing, glob never matched

`signalloom-agent-generic` (`d2-signalloom/infra/inf-bao/controllers/base/openbao-agent-generic-role.yaml`) declared `bound_claims: {"sub": ".../sa/*"}` with no `bound_claims_type`, so OpenBao defaulted to `string` and compared the trailing `*` as a literal character. Every one of the 18 registered `fe-signalloom-agents/sa/*` identities (`cpai-engineer`, `swarm-governor`, every `kagent-*` analyst) was permanently denied — a correctness/availability defect that happened to fail closed, not an exploitable bypass.

**Fix:** added `"bound_claims_type": "glob"`, back-porting the same fix already applied to `signalloom-cardvault-agent` and the federated `osramp.local` `agent-cardvault` role (documented there as defect `PF-3`).

**Before/after (live, `kind-osramp`):** `bound_claims_type`: `string` → **`glob`**. A real, correctly-audienced SVID for `agent-cardvault` now authenticates successfully against this role (`SPIFFE-12`: `claim-mismatch-for-every-agent` → `login-succeeded`).

## Findings deferred (same card, LOW/INFO severity)

| Finding | Severity | Reason deferred |
| --- | --- | --- |
| F3 — `risk-reader`/`investigator` delegation gap | LOW | Both identities are labelled `agent-trust.signalloom.io/scaffold: "true"` and `scripts/agent-trust-local.sh` asserts their egress to OpenBao is `deny` by design (`expect_tcp agent-trust-risk-reader agent-trust-acme-risk openbao.inf-bao.svc 8200 deny`). Provisioning a role they cannot network-reach would not close a real gap. |
| F4 — SPIRE agent `insecure_bootstrap`/`skip_kubelet_verification` | LOW | Demo-appropriate per the P1-3 dossier's own framing ("before any non-local deployment"). Flipping either on the one live, shared, single-replica SPIRE agent risks cluster-wide SVID-issuance loss for every concurrent sibling card, with no tested rollback path. |
| F5 — `agent-cardvault` hostPath vs. `spiffe-csi-driver` | INFO | Requires a live Deployment rollout on a cluster other sibling cards are actively using. Deferred to keep this card's blast radius to declarative role/policy edits only. |
| F6 — static root token | INFO | Pre-existing accepted demo convention; rotating it touches every bootstrap Job's `BAO_TOKEN` env and risks locking out live re-bootstraps. |

## New finding discovered during verification (not in F1-F6, deferred)

**`signalloom-agent-templated`'s identity-templated KV policy path has never been reachable — by anyone, including the legitimate agent it's meant to serve — and is unrelated to the F2 glob fix.**

With F2 fixed, `signalloom-agent-generic` logins now succeed, so this card went one step further than the Required Tests ask and live-tested whether the resulting batch token can actually read its own templated KV path (`kv/data/agents/{{identity.entity.aliases.auth_jwt.metadata.sub}}/*`) — the thing F2's fix was supposed to finally unlock. It cannot, for a reason independent of F2:

- `auth/jwt` is one shared mount serving every role in this file family (`signalloom-cardvault-agent`, `signalloom-fe-signalloom`, `signalloom-agent-generic`, `agent-trust-*`). OpenBao keys an identity-entity alias by `(mount_accessor, name=sub-claim-value)`, so the *same* SPIFFE identity logging in via *different* roles on that one mount shares *one* alias record.
- Only `signalloom-agent-generic` declares `claim_mappings: {"sub": "sub"}` to populate `alias.metadata.sub`. Every other role sharing the mount does not. Because alias metadata is overwritten (not merged per-role) on each login, whichever role that identity logged in via *most recently* — including an unrelated `signalloom-cardvault-agent` login from a completely different test run — determines what `{{identity.entity.aliases.auth_jwt.metadata.sub}}` resolves to for every policy referencing that alias, for every token, retroactively.
- Separately, the raw `sub` claim is a full SPIFFE URI (`spiffe://signalloom.demo/ns/.../sa/...`). Its `//` is collapsed by standard HTTP path normalization — reproduced live against OpenBao's own `bao` CLI, not a theory — so even a perfectly-resolved template segment does not survive the request path unmangled.
- Live-verified (`kubectl exec` against the real `kind-osramp` OpenBao, three separate identity-templated path shapes tried: the guessed de-prefixed form, the literal `spiffe://`-prefixed form, and a `list` on the prefix): **every read attempt returned `403 preflight capability check`, including the legitimate agent reading its own intended path.** This is a **correctness/availability defect that fails closed** — the same class as F2 before its fix, not a new exploitable gap, and not a regression this card introduced (F1/F2 do not touch `signalloom-agent-templated` or its policy).

**Not fixed in this card.** It requires an actual design decision — e.g., moving away from shared-mount identity-templating toward the explicit `bound_subject` + dedicated-policy pattern that `signalloom-cardvault-agent`, `signalloom-fe-signalloom`, and every `agent-trust-*` role already use correctly — not a one-field surgical edit, and it is not named in this card's Objective/Approach/Deliverables. Recorded here so it is not lost: recommend a follow-up card (`SLAAT-P2-GOV` triage or a new Phase 3 finding) to either retire `signalloom-agent-templated`/`signalloom-agent-generic` in favour of per-agent roles (matching `scripts/kagent-credentials.sh`'s already-correct per-agent pattern), or give each identity logging in via multiple roles a role-scoped alias instead of a mount-scoped one.

## Regression evidence

- `scripts/probe-spiffe-privilege-escalation.sh`: 19 records, **fail_count 4 → 0**. `SPIFFE-3`, `TTL-signalloom-cardvault-agent`, `TTL-signalloom-fe-signalloom`, `SPIFFE-12` all flipped to `pass`; all 15 previously-passing records (forged identity, cross-identity, wrong-audience, tampered signature, `alg:none`, cross-tenant KV isolation) remain `pass` — zero regressions.
- `scripts/probe-openbao-acls.sh`: the 4 `ACL-POLICY-*` (wildcard-boundary) records remain `pass`; the 6 pre-existing `ACL-GAP-*` delegation-gap records (F3 and the unrelated `EAPR` identities) are unchanged, as expected from the deferral decision above.
- `test/spiffe-openbao-adversarial.bats`: 16/16 pass.
- `test/openbao-security-probes.bats`: 8/8 pass.
- `test/spiffe-openbao-policy-hardening.bats` (new): 14/14 pass.
- `python3 -m pytest d2-agent-trust/test/test_contracts.py`: 8/8 pass (substituted for the card's literal `d2-agent-trust/test/run-trust-tests.sh`, which does not exist in this repo — see errata).
- Direct `curl` against the live, port-forwarded OpenBao JWT login endpoint: a forged `alg:none` claim returns `400` (OpenBao's actual fail-closed status for a login/signature error, not `403` — same behaviour already documented in the P1-3 dossier's B5); a forged bearer token against a tenant KV path returns `403`.

Machine-readable twin: `ci-evidence/slaat-p2-3-spiffe-remediation.json`. Raw live-probe evidence: `ci-evidence/slaat-p2-3-postfix-spiffe.json`, `ci-evidence/slaat-p2-3-postfix-openbao-acls.json`.
