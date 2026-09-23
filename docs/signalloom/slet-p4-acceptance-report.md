# SLET-P4-2 — kurasi Tenant Isolation Acceptance Report

**Card:** SLET-P4-2 (implementation) · **Base:** `integration/slet-v0.1.0` @ `13c87855`, built on SLET-P4-PRE `afee7093` · **Run:** 2026-09-23 · **Cluster:** `kind-osramp` (Kubernetes v1.36.1, Cilium, SPIRE 1.11.1, OpenBao 2.1.1 `-dev`)

## Verdict

The pilot tenant **kurasi** (`6f82ad81`, namespace `eap-6f82ad81`) passes all seven lifecycle stages on two tiers: hermetically through the real FastAPI app, and live against the kind cluster's API server, Cilium, SPIRE and OpenBao. The suite passed **10 of 10 consecutive live iterations (440/440 test executions, 0 flakes)**. Each of the **10 security controls** it guards was deleted in turn, and the suite failed every time.

The run also turned up **four defects in the prior engine** (fixed here) and **four environment findings** that the proposal needs to absorb (recorded below, not fixed, because they are outside this card).

## Scope delivered

| Deliverable | Where |
| :--- | :--- |
| Acceptance suite (tier 1 + tier 2) | `d2-signalloom/apps/fe-signalloom/src/tests/test_kurasi_tenant_isolation.py` |
| Transit key lifecycle (create / encrypt / decrypt / shred) | `d2-signalloom/apps/fe-signalloom/src/tenant_transit.py` |
| Engine: shred-on-teardown, rollback, SVID verifier, cross-tenant predicate, transit API | `d2-signalloom/apps/fe-signalloom/src/tenant_isolation.py` |
| Runner (N iterations, live tier, evidence capture) | `scripts/eap/run_slet_p4_2_acceptance.sh` |
| Evidence (transcript, metrics, stability log, mutation log) | `docs/signalloom/evidence/slet-p4-2/` |

Reproduce:

```bash
scripts/eap/run_slet_p4_2_acceptance.sh                                  # tier 1
scripts/eap/run_slet_p4_2_acceptance.sh --live --iterations 10 \
  --evidence-dir /tmp/slet-evidence                                      # tier 1 + 2, x10
```

## Prior-work verification

These rows were checked before I wrote anything new, following the card's protocol.

| Artifact | Probe | Result |
| :--- | :--- | :--- |
| `src/tenant_isolation.py` (329 lines @ `13c87855`) | read in full; `pytest tests/test_eap_tenant_isolation.py` | 9/9 pass. Gaps found: no transit code at all; teardown only set `is_active=False`; `/manifests` fabricated a kurasi-labelled namespace for any hash; DNS egress admitted every kube-system pod |
| `src/main.py` wiring | `rg -n tenant_isolation main.py` | imported at line 20, mounted at line 46 |
| 1935 deleted test lines (`13c87855`) | `git show --stat 13c87855`; `git show 13c87855^:…/test_tenant_isolation.py` | a same-name overwrite of the 30-test AMXO cross-tenant authz sweep. **Restored by SLET-P4-PRE `afee7093`**, which is not yet on the integration branch; this card is built on it (see the SLET-P4-2 errata) |
| Required suites @ `afee7093` | `pytest test_tenant_isolation test_eap_tenant_isolation test_webhook_triggers test_environment_routing` | **139 passed** |
| `scripts/eap/test_tailscale_eap_env.sh` | `bash` | **15 passed, 0 failed** |
| `scripts/eap/test_emit_eap_webhook.sh` | `bash` | **9 passed, 0 failed** |
| P4-1 "transit lease manager" (row says Pass `13c87855`) | `rg transit tenant_isolation.py@13c87855` | **absent**. Minimal lifecycle implemented here so shredding could be proven |
| P3-2 "SPIFFE CSI driver binding" | `kubectl get csidriver` | **no CSI drivers installed** (finding F3) |

Baseline logs: `evidence/slet-p4-2/baseline-required-tests.txt`.

## Stage results

### Stage 1 — Boundary provisioning

`POST /api/v1/eap/tenants {"company_name":"kurasi"}` → `201` with the exact body below:

```json
{"company_name":"kurasi","customer_hash":"6f82ad81","namespace":"eap-6f82ad81",
 "spiffe_id":"spiffe://osramp.local/ns/eap-6f82ad81/sa/tenant-app",
 "transit_key_path":"transit/keys/eap-6f82ad81","is_active":true}
```

The hash is recomputed from its definition, `sha256("signalloom-eap-salt-2026-q3:kurasi")[:8] = 6f82ad81`, so the suite never takes it on trust. The plan row's spelling **"kusari" hashes to `4b53ab6b`, which is a different tenant**. The suite pins that as well, and uses `4b53ab6b` as a cross-tenant attacker identity.

Live: both tenant namespaces are created from the engine's own manifests, then read back from the API server.

### Stage 2 — Pod Security Standards

The manifest carries `enforce`, `audit` and `warn` set to `restricted`, plus `enforce-version: latest`. The API server's own readback shows the same labels. The live PSA check sends two pods through `kubectl create --dry-run=server`:

- a restricted-compliant pod is **admitted** (rc 0). This is the positive control.
- a privileged, root pod is **refused** (rc 1) with `violates PodSecurity "restricted:latest": privileged …, allowPrivilegeEscalation != false …, unrestricted capabilities …, runAsNonRoot != true …, runAsUser=0 …, seccompProfile …`

The card names "succeeds when the PSS restricted labels are missing" as a known failure mode. To rule it out, the check was run against 8 mutated manifests (no `enforce` label, `baseline`, `privileged`, no `audit` label, no `warn` label, no labels at all, wrong hash, wrong name). **It rejected every one.**

### Stage 3 — NetworkPolicy

Two checks cover the policy:

- **Shape check:** `podSelector: {}`, both policy types, no `ipBlock`, no empty peer lists, no port-less rules, ingress only from `ingress`/`fe-signalloom` on TCP/8080, DNS only to `k8s-app=kube-dns` on 53.
- **Semantic check:** an evaluator of Kubernetes peer semantics (namespace and pod selectors ANDed within a peer) produces a 14-flow traversal matrix, and each flow is asserted.

Live, Cilium enforced the policy between real pods:

| Flow | Expected | Observed |
| :--- | :---: | :---: |
| ingress-ns → kurasi:8080 (positive control) | allow | reached |
| kurasi → kube-dns (positive control) | allow | reached |
| ingress-ns → kurasi:9090 (only kurasi's ingress port list can refuse this) | deny | refused |
| kurasi → ingress-ns:8080 (only kurasi's egress can refuse this) | deny | refused |
| peer tenant → kurasi:8080 | deny | refused |
| kurasi → peer tenant:8080 | deny | refused |
| kurasi → openbao:8200 | allowed by the tenant policy | **refused by `inf-bao` default-deny** (finding F2) |

Each denial is attributable to a single policy, and each has a positive control showing the listener was up. A denial with no working allow path proves nothing about enforcement.

### Stage 4 — SPIFFE attestation

The engine's registration entry is `spiffe_id = spiffe://osramp.local/ns/eap-6f82ad81/sa/tenant-app`, selectors exactly `{k8s:ns:eap-6f82ad81, k8s:sa:tenant-app}`, `ttl = 3600`, `admin = false`.

Live against the real SPIRE server:

- **Registering the proposal's ID is rejected**: `status.code 3: invalid parent ID "spiffe://osramp.local/spire/agent/k8s-node" is not a member of trust domain "signalloom.demo"`. `spire-server` exits **0** on this failure, so the test reads the JSON status code instead of trusting the exit code. That rejection is finding F1.
- Registration under the server's own trust domain succeeds. On readback the selectors match exactly and `x509_svid_ttl = 3600`.
- `spire-server x509 mint -ttl 1h` issues a real SVID. `verify_tenant_svid` accepts it for kurasi: exactly one URI SAN equal to the tenant ID, not a CA, lifetime 3610s = 1h plus SPIRE's 10s `NotBefore` backdate. It **rejects the same certificate for the peer tenant**. With `skew_seconds=0` it also rejects the certificate, which shows the 10s allowance is what admits SPIRE's backdate and nothing looser.

Tier 1 runs the same verifier against locally minted certificates. It rejects: a cross-tenant ID, two URI SANs, no SAN, a 2h lifetime, a 3611s lifetime, and a CA certificate.

### Stage 5 — Cryptographic transit

- Ciphertext has the form `vault:v1:<base64(nonce‖ct‖tag)>` and its decoded length is exactly 12 + len(plaintext) + 16. The plaintext bytes do not appear in it.
- Two encryptions of the same payload differ, so nonces are not reused.
- Round-trip decrypt returns the payload.
- Tampered, re-versioned, malformed and truncated ciphertexts are all rejected.
- Live: a real OpenBao key `transit/keys/eap-6f82ad81` is created (`type: aes256-gcm96`, `deletion_allowed: true`) and used through the production `OpenBaoTransitBackend`. Sample ciphertext: `vault:v1:xO2uSJD739lhK/6J…`.

### Stage 6 — Teardown and shredding

`DELETE /api/v1/eap/tenants/6f82ad81` returns a shred receipt. The iteration-1 proof artifact:

```json
{"ciphertext": "vault:v1:f+XcrfR51XaeqJSN…", "post_shred_decrypt_status": 404,
 "receipt": {"backend": "in-memory-aes256-gcm96", "key_path": "transit/keys/eap-6f82ad81",
   "key_fingerprint_sha256": "a58734796be58d73cf88581ef6a4acf1af1fcba9ee7dac11a80756f983b807e5",
   "material_zeroised": true, "shredded_at": "2026-09-23T02:06:30.485726+00:00"}}
```

What this proves:

- **The destroyed key is the one that sealed the data.** The fingerprint in the receipt equals SHA-256 of the key bytes captured just before shredding.
- **The key bytes are gone.** The test holds a reference to the backend's own `bytearray` and reads back 32 zero bytes after teardown.
- **The key name is gone.** `key_exists` is false, and decrypt returns 404.
- **Re-provisioning cannot revive the data.** A new tenant under the same name gets a different key (different fingerprint), and the old ciphertext fails authentication. This rules out "unrecoverable because the name is missing" as the only protection.
- Live: OpenBao `GET transit/keys/eap-6f82ad81` returns **404** after shredding, and decrypting the old ciphertext raises `TransitKeyNotFound`. The SPIRE entry is deleted and a readback shows zero entries. Both namespaces are deleted and confirmed `NotFound`.
- Teardown is idempotent. A second DELETE returns the original receipt and does not shred again.

### Stage 7 — Negative traversal

- **API:** 10 caller identities are refused with `403`: none, empty, the `kusari` tenant, prefix extension (`…ad810`), truncation, another service account in the same namespace, a foreign trust domain, case variation, a trailing slash, and query smuggling. A positive control shows the owner is admitted, so the 403s are not an endpoint that rejects everyone.
- **Cryptographic:** the peer tenant, calling through its own endpoint with its own identity, cannot decrypt kurasi's ciphertext (GCM authentication fails). This holds on the in-memory backend and on live OpenBao.
- **Network:** see Stage 3.
- **Identity:** an SVID minted for another tenant is rejected for kurasi.
- **Fabrication:** `GET /eap/tenants/deadbeef/manifests` now returns `404`. It previously returned a namespace labelled `signalloom.io/customer: kurasi`.

## Rollback, concurrency, stability

- **Faults during provisioning roll back completely.** Three injected faults were tested: OpenBao unavailable during key config (after the key exists), OpenBao unreachable (before the key exists), and boundary validation failing after key creation. In each case no boundary is recorded and no key is left behind. The next attempt then provisions cleanly.
- **Concurrent provisioning of one tenant produces one boundary.** 32 threads provisioning kurasi behind a barrier produce one config object and one key. 32 concurrent teardowns produce one shred.
- **Mixed concurrent traffic keeps the key invariant.** 600 random provision/teardown operations across 12 tenants on 24 threads (seeded, so reproducible) leave `active ⇔ key exists` true for every tenant.
- **The ASGI stack handles parallel journeys.** 20 parallel provisions, 50 parallel encrypt/decrypt round-trips and 20 parallel teardowns through `httpx.ASGITransport` finish with zero active boundaries and zero keys.
- **Stability:** 10 consecutive runs of the full suite including the live journey: **44 passed each, 0 failed** (`evidence/slet-p4-2/stability-10-iterations.txt`).

## Performance (10 iterations)

| Stage | n | wall ms (median / max) | CPU ms (median / max) | peak heap KiB (median / max) |
| :--- | ---: | ---: | ---: | ---: |
| `1-provision` | 10 | 7.8 / 11.0 | 8.1 / 10.5 | 128.6 / 130.7 |
| `2-pss` | 10 | 0.0 / 0.0 | 0.0 / 0.0 | 0.2 / 0.2 |
| `3-netpol` | 10 | 0.3 / 0.4 | 0.3 / 0.4 | 2.1 / 2.1 |
| `4-spiffe` | 10 | 6.9 / 15.8 | 7.0 / 8.0 | 257.7 / 258.4 |
| `5-transit` | 10 | 8.1 / 8.9 | 8.4 / 9.2 | 128.9 / 131.5 |
| `7-negative` | 10 | 5.1 / 5.7 | 5.3 / 5.9 | 77.6 / 78.4 |
| `6-teardown` | 10 | 10.2 / 11.1 | 10.7 / 11.6 | 119.8 / 122.3 |
| `perf-crypto-1000x4KiB` | 10 | 26.5 / 28.2 | 26.5 / 28.2 | 5441.3 / 5441.3 |
| `live-1-namespaces` | 10 | 207.6 / 236.4 | 2.5 / 2.9 | 69.0 / 69.0 |
| `live-2-psa` | 10 | 113.9 / 129.3 | 1.9 / 2.1 | 70.0 / 70.0 |
| `live-3-netpol` | 10 | 51161.8 / 51414.1 | 23.9 / 25.7 | 73.5 / 74.3 |
| `live-4-spire` | 10 | 401.2 / 727.3 | 5.7 / 6.1 | 141.2 / 141.3 |
| `live-5-transit` | 10 | 227.8 / 230.1 | 23.2 / 24.9 | 204.2 / 204.4 |
| `live-6-teardown` | 10 | 10882.7 / 12712.2 | 17.2 / 19.4 | 152.9 / 153.2 |

Peak cryptographic workload: 1,000 × 4 KiB seal-and-open cycles take about 26 ms of CPU. The 5.3 MiB peak heap is the 1,000 ciphertexts the test holds, not per-operation overhead. The CPU columns show that the live stages are dominated by waiting on the cluster. In `live-3-netpol`, each deny probe must exhaust its 3s timeout three times before it counts as a denial. Heap figures are Python `tracemalloc` peaks for the test process; cluster-side resource use is not measured.

## Guard falsification (mutation run)

Each control was removed from the engine source and the suite re-run. **10 of 10 mutations were killed** (`evidence/slet-p4-2/mutation-run.txt`), and the source was restored byte-identical afterwards.

| Mutation | Tests failed |
| :--- | ---: |
| teardown flips the flag and does not shred | 6 |
| authz uses a prefix match | 4 |
| DNS egress open to all of kube-system | 8 |
| PSS `enforce` label removed | 9 |
| provisioning rollback removed | 2 |
| `/manifests` fabrication restored | 1 |
| shred without zeroising | 3 |
| fixed nonce | 2 |
| `deletion_allowed` guard removed | 1 |
| peer tenant admitted to ingress | 8 |

## Defects fixed in the prior engine

1. **Teardown did not shred.** It only set `is_active=False`, which is exactly the "marked inactive, not shredded" failure mode the card warns about. Teardown now shreds the transit key and returns a receipt.
2. **`/manifests` misattributed tenants.** For any unknown hash it returned a namespace labelled `signalloom.io/customer: kurasi`, and `test_api_tenant_manifests_and_spire` only passed because of that. It now returns `404`, and the test provisions first.
3. **DNS egress was too broad.** The kube-system peer had no `podSelector`, so every kube-system pod was reachable on port 53. It is now pinned to `k8s-app: kube-dns`, per Pattern 2.
4. **Transit did not exist.** The P4-1 row claims a lease manager, but the code had none. The minimal lifecycle added here uses the P4-PRE runbook order: enable deletion, then delete.

## Findings for the proposal (not fixed; outside this card)

- **F1 — Trust domain mismatch.** The proposal and engine use `osramp.local`; the cluster's SPIRE runs `signalloom.demo` and rejects `osramp.local` registrations. The trust domain is now overridable through `SLET_SPIFFE_TRUST_DOMAIN`, with `osramp.local` kept as the default that tier 1 pins. Either the proposal changes to `signalloom.demo`, or SPIRE gets a federated or renamed trust domain.
- **F2 — The OpenBao egress rule is inert.** The tenant NetworkPolicy allows egress to `inf-bao:8200`, but `inf-bao`'s own `default-deny` does not admit `eap-*`. That is the safer posture, because tenants never call OpenBao directly (SLET encrypts on their behalf). The egress rule should be removed, or opened on purpose. The engine also targets a namespace `inf-spire` that does not exist; SPIRE runs in `inf-bao`.
- **F3 — Tenant pods cannot fetch SVIDs.** No SPIFFE CSI driver is installed, and PSS `restricted` forbids the hostPath volume the SPIRE agent socket normally uses. So a tenant pod has no path to its SVID today. Registration and minting are proven; delivery to a workload is not. The P3-2 row's claim is unevidenced.
- **F4 — Mutating routes are unaudited.** `test_audit_provenance::test_every_mutating_route_makes_an_audit_decision` was already failing at base with 8 routes: SLEA environments ×4, SLTE webhooks ×2, SLET provision/teardown ×2. This card's two transit routes are declared `AUDIT_DECISION_OWED` (judged audit-worthy, audit write not yet built), so the count stays at 8 rather than rising to 10. The full-suite result is otherwise 1533 passed.

## Honest limits

- The `X-SPIFFE-ID` header stands in for identity. In the deployed topology the identity must come from the verified mTLS peer SVID. This card proves the **authorization predicate**, not identity binding.
- In-memory "zeroisation" covers the backend's stored `bytearray`. Transient `bytes` copies made during AES operations are not reachable for overwrite in Python. OpenBao never exposes key bytes, so the live proof of absence is the 404 readback.
- The OpenBao used is a `-dev` in-memory server. The runner script reads its dev token from the Deployment at runtime, refuses to do so for a non-`-dev` server, and never prints or writes the token (the evidence was scanned for it).
- Tier 2 needs a cluster and is skipped with a stated reason elsewhere, so standalone or CI checkouts without a cluster run tier 1 only (43 tests). "Monorepo CI" was not exercised beyond running the full fe-signalloom suite locally.
- Zero persistent artifacts: after all 10 live iterations there were no `eap-*` namespaces, no probe pods, no `eap-` SPIRE entries and no transit mount. The run mounts transit only when it is absent, and unmounts it only if the run mounted it and no keys remain.
