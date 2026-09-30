# SLDC-P3-PRE - Tenant Domain Derivation Inventory

Phase 3 pre-flight for the SLDC board. This records how the EAP tenant domain is
derived today, what the Phase 3 cards (P3-1 hash generator, P3-2 HTTPRoute/Dex
alignment) must change, and the evidence behind each claim. It is a read-only
audit: no application code, manifest, or OpenBao value was changed.

- Scanned commit: `1d84ff381b34b4463fd017d462fdc0632db2fa6e` (tip of `integration/sldc-v0.1.0`)
- Machine-readable report: [`ci-evidence/p3-preflight-audit.json`](../../ci-evidence/p3-preflight-audit.json)
- Regenerate: `scripts/p3-tenant-preflight.sh audit --out ci-evidence/p3-preflight-audit.json`
- Tests: `bats test/p3-tenant-preflight.bats` (14 tests; 5 deliberate mutants all killed)

## 1. The derivation rule, as implemented

Every production derivation in the repository uses one formula:

```
customer_hash = sha256( salt + ":" + lower(trim(tenant)) ).hexdigest()[0:8]
hostname      = "sl-eap-" + customer_hash
```

Implementations:

- `d2-signalloom/apps/fe-signalloom/src/environment_routing.py` - `derive_customer_hash()`
- `scripts/eap/tailscale-eap-env.sh` - `hash` subcommand

Vectors under the pilot salt `signalloom-eap-salt-2026-q3`, recomputed from
their definitions by the audit script:

| Input | Formula | Digest | Status |
| :-- | :-- | :-- | :-- |
| `kusari` | `sha256(salt:tenant)[0:8]` | `4b53ab6b` | **canonical** |
| `kurasi` | `sha256(salt:tenant)[0:8]` | `6f82ad81` | retired, must fail closed |
| `kusari` | `sha256(tenant)[0:8]` (unsalted) | `d9d69501` | rejected |
| `kusari` | `HMAC-SHA256(key=salt, msg=tenant)[0:8]` | `4a89f30d` | not in use |
| `kurasi` | `HMAC-SHA256(key=salt, msg=tenant)[0:8]` | `b4c188df` | not in use |

### Spec discrepancy (blocking for P3-1's wording, not for the vector)

The card and the P3-1 title name the formula **HMAC-SHA256(salt, tenant)[0:8]**
and assert it yields `4b53ab6b`. It does not: HMAC yields `4a89f30d`. The
canonical digest `4b53ab6b` is produced only by the salted concatenation above,
which is what the code, the Phase 2 evidence (`sl-eap-4b53ab6b.ts.net` in
`test/fixtures/phase2-governor/hub-fixture.yaml`) and all pinned tests use.

Both statements cannot hold. Shared Pattern 1 and the verified facts fix the
**vector** (`kusari` → `4b53ab6b`), so the **formula text** is the erratum.
Recommendation to the Governor: P3-1 implements
`sha256(salt + ":" + normalised_tenant)[0:8]` and the proposal's Appendix C.1
text changes to match. Switching to HMAC would re-key every EAP hostname,
namespace and SPIFFE ID derived from the hash, which is a migration, not a
tightening.

Security note on that choice: HMAC would be the textbook construction for a
keyed digest, but here the salt is published in the docs and pinned in tests,
so it is a domain separator rather than a secret. Length extension against
`sha256(salt:…)` is also moot because only 32 bits of output are exposed. If
the salt is ever meant to be secret (a random value seeded into OpenBao), that
is the moment to move to HMAC. It would be a planned re-key, done once.

## 2. Salt source

| Source | State on 2026-09-30 | Evidence |
| :-- | :-- | :-- |
| `SIGNAL_LOOM_EAP_SALT` env | honoured first by Python and shell | `environment_routing.py:73`, `tailscale-eap-env.sh:29` |
| OpenBao KV `secret/signalloom/eap` field `salt` | **not provisioned** | `bao kv get` on `kind-osramp` → `No value found at secret/data/signalloom/eap`, exit 2 |
| OpenBao on `kind-signalloom-hub` | **absent** | `namespaces "inf-bao" not found` |
| Hard-coded default | none, deliberately | an earlier governor removed `DEFAULT_EAP_SALT`; missing salt raises / exits non-zero |

Findings:

1. **The path is KV, not transit.** The card calls `secret/signalloom/eap` a
   "transit secret engine" path. `bao secrets list` shows `secret/` is a `kv`
   mount; `transit/` is a separate mount. The salt is a KV secret.
2. **No policy grants read on the salt path.** The five ACL policies
   (`agent-trust-acme-payments`, `default`, `signalloom-agent-templated`,
   `signalloom-cardvault-agent`, `signalloom-fe-signalloom`) reference only
   `kv/data/...`. None names `secret/data/signalloom/eap`, so no tenant
   bootstrap role can read it today even once seeded.
3. **No deployment wires the salt.** No Deployment on `kind-osramp` sets
   `SIGNAL_LOOM_EAP_SALT`; one (`fe-signalloom-agents/agent-cardvault`) sets
   `BAO_ADDR` without `BAO_TOKEN`, so the Python OpenBao branch is unreachable.
4. **The seeding script would break the canonical vector.**
   `scripts/eap/seed-eap-salt.sh` writes a *random* 32-byte salt. Any salt
   other than `signalloom-eap-salt-2026-q3` gives `kusari` a hash other than
   `4b53ab6b`. Seeding must write the pilot salt, or the canonical vector must
   be declared salt-specific.
5. **Hermetic fallback exists and is explicit.** Offline suites set
   `SIGNAL_LOOM_EAP_SALT` themselves (`conftest.py` uses `test-eap-salt-2026`;
   `eap-ingress-reconcile.bats` likewise). Adding an *automatic* default, as the
   card's failure-mode remediation suggests, would reverse the earlier
   fail-closed decision; this audit recommends against it. Under the pilot salt
   the fallback reproduces `4b53ab6b` (shell and Python both verified).

## 3. Legacy string inventory

Scan: `git grep -i -E 'kurasi|6f82ad81'` and `git grep d9d69501` across every
tracked text file, excluding this audit's own deliverables.

| Category | Occurrences | Meaning |
| :-- | --: | :-- |
| `active_code` | 1 | executes in production |
| `published_docs` | 22 | ships to operators |
| `test_fixture` | 6 | tests that pin current behaviour |
| `historical_record` | 820 | ledgers, evidence, past reports - not rewritten |
| **total** | **849 in 40 files** | |

Unsalted digest `d9d69501`: **0 occurrences**. No component uses unsalted
`sha256(tenant)` for tenant domains. The only `sha256`/`hmac`-near-`tenant`
hits are unrelated (credential token hashes, HKDF tenant KEKs, pseudonyms).

### Active occurrences for P3-1 / P3-2 to eliminate

1. **`d2-signalloom/apps/stun-sentinel/pkg/correlator/ebpf_correlator.go:402`** - 
   a `tenant` label of `kurasi` is silently rewritten to `kusari`. This
   *accepts* the typo instead of failing closed, contrary to Shared Pattern 1.
   Pinned by `ebpf_correlator_test.go:302-306`
   (`TestForbiddenKurasiTypoCorrection`) and `test/unit/correlator-pipeline.bats:49-52`.
   Both tests must invert to assert rejection when the code changes. Owner:
   P3-1 (it is tenant-identity code, not telemetry).
2. **`d2-signalloom/apps/docs-signalloom/src/content/docs/operate/environment-routing.mdx`** - 
   the published operator guide still teaches `kurasi` → `6f82ad81`,
   `sl-eap-6f82ad81`, `env-6f82ad81-eap`, and an example `--company "kurasi"`.
   22 lines. Replace with `kusari` / `4b53ab6b`.

### No production validator rejects `kurasi` today

The objective asks to confirm the typo is "rejected by all validators". On
disk it is not:

- `derive_customer_hash("kurasi")` returns `6f82ad81` without error.
- `tailscale-eap-env.sh hash kurasi` prints `6f82ad81`, exit 0.
- The sentinel canonicalises it (above).

Rejection currently exists only as test assertions and as this audit's
`classify` oracle (`scripts/p3-tenant-preflight.sh classify kurasi` → exit 3).
P3-1 needs a production fail-closed check on both name and digest.

## 4. Gateway and Dex readiness for `sl-eap-4b53ab6b.ts.net`

| Surface | State | P3-2 action |
| :-- | :-- | :-- |
| `d2-infra/components/ingress/eap-httproute-template.yaml` | parameterised on `${EAP_HASH}` for `.tailscale` and `.ts.net` | render with `EAP_HASH=4b53ab6b`; no hard-coded legacy host |
| `d2-signalloom/infra/inf-signalloom/base/dex.yaml` `signalloom-dashboard.redirectURIs` | no `sl-eap-*` URI (canonical or legacy) | add `https://sl-eap-4b53ab6b.ts.net/callback` |
| `d2-signalloom/apps/fe-signalloom/base/gateway-route.yaml` | `dashboard.${CLUSTER_DOMAIN}` only | none unless the EAP host must reach the dashboard route |
| Manifests naming the canonical host | only `test/fixtures/phase2-governor/hub-fixture.yaml` | - |

No manifest carries a legacy `sl-eap-6f82ad81` or `sl-eap-d9d69501` host.

## 5. What gates P3-1 and P3-2

| # | Gate | Blocking? | Owner |
| :-- | :-- | :-- | :-- |
| G1 | Correct the formula text from HMAC-SHA256 to `sha256(salt:tenant)[0:8]` (or approve a re-key to HMAC) | **yes, for P3-1** | Governor |
| G2 | Seed `secret/signalloom/eap` with the pilot salt and add a read policy for the bootstrap role; stop `seed-eap-salt.sh` writing a random salt | yes for live P3-GOV; no for offline P3-1 | cluster bootstrap (out of scope here: no OpenBao writes) |
| G3 | Replace the sentinel's `kurasi` canonicalisation with fail-closed rejection and invert its two pinning tests | yes, P3-1 scope | P3-1 |
| G4 | Rewrite `environment-routing.mdx` to the canonical vector | no | P3-1 or P3-2 |
| G5 | Add the canonical Dex redirect URI | yes, P3-2 scope | P3-2 |
| G6 | The card's required test "OpenBao on `kind-signalloom-hub`" targets a cluster with no `inf-bao` namespace; OpenBao runs on `kind-osramp` | spec correction | Governor |

## 6. Baseline at this commit

- `make test` (live bats): 8 ran, 0 skipped, exit 0.
- `make test-eap-offline`: **red, pre-existing**. 246 pytest passed, 4 failed
  (`test_tenant_isolation.py` ×2, `test_audit_provenance.py` ×2), and 1 bats
  failed (`api-route-liveness.bats` #6). All five trace to
  `GET /api/v1/discovery/workloads` (commit `12706631`, 2026-09-29), which has
  no `DB_ROUTES` / audit decision and a `request` kwarg mismatch. That is
  application work outside Phase 3, so it is recorded here and not fixed. Phase 3 cards
  measure their delta against this red set.
- `go test ./pkg/correlator/ ./pkg/filter/` (stun-sentinel): ok.
- `pytest tests/test_tenant_vector.py tests/test_environment_routing.py`: 21 passed.
