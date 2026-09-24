# SLET v0.1.0 — Phase 4 Governor Certification

**Verdict: NOT CERTIFIED. SLET is not ready for production EAP enablement.**

- Governor card: `SLET-P4-GOV` (task `7744e`)
- Assessed: `integration/slet-v0.1.0` at merge `c9919949`
  - Base: `13c87855a506f4c2c436228d6056ca3c5d6e7bd0`
  - Merged in: `afee7093` (P4-PRE) and `5cbd9749..5ee1de35` (P4-2)
  - The merge tree is byte-identical to `5ee1de35`.
- Assessed on: 2026-09-23
- The merge exists to preserve the P4 chain. No ref held it and it was at risk of garbage collection. No release tag has been created.

This file is at the path the card named for the mission-complete certificate. The evidence does not support a certificate, so it records why one was refused. The other certification artefacts the card listed are withheld, because each would attest to something the evidence contradicts:

- architecture / defence-in-depth sign-off
- DR / rollback runbook
- container-signature sign-off
- prompt-contract compliance audit
- release-tag artefact

The prior "Pass" at `53246f43` (`slet-p4-gov-review.md`) is on a different lineage, was rejected by the 2026-09-22 council, and is not merged.

## What verifies

| Artifact | Probe | Result |
| :-- | :-- | :-- |
| Kurasi vector | `derive_customer_hash("kurasi")` via the live module | `6f82ad81`; namespace `eap-6f82ad81`; SPIFFE `spiffe://osramp.local/ns/eap-6f82ad81/sa/tenant-app`; transit `transit/keys/eap-6f82ad81` |
| `tenant_isolation.py`, `tenant_transit.py` | `rg`; `main.py:20,46` | Present and mounted |
| SLET/SLEA/SLTE + authz sweep + kurasi suite | `pytest test_tenant_isolation.py test_eap_tenant_isolation.py test_kurasi_tenant_isolation.py test_webhook_triggers.py test_environment_routing.py` | 182 passed, 1 skipped |
| Shell suites | `test_tailscale_eap_env.sh` / `test_emit_eap_webhook.sh` | 15/0 and 9/0, rc=0 |
| `/manifests` for an unknown hash | `GET /api/v1/eap/tenants/KUBE-SYSTEM!!/manifests` | 404 (fixed by P4-2; at `13c87855` it returned 200 with namespace `eap-kube-system!!`) |
| Live tier-2 journey | not re-run by this governor (it would mutate kind-osramp) | P4-2 recorded 440/440 over 10 iterations in `docs/signalloom/evidence/slet-p4-2/`. This is inherited evidence, not re-observed. |

## Blockers

1. **Anonymous decrypt of tenant data.** Measured through `TestClient(main.app)` with no bearer token:
   - `POST /api/v1/eap/tenants/6f82ad81/transit/encrypt` with only the header `X-SPIFFE-ID: spiffe://osramp.local/ns/eap-6f82ad81/sa/tenant-app` returns `200` and a `vault:v1:` ciphertext.
   - `POST …/transit/decrypt` with the same forged header returns `200 {"plaintext":"Y3VzdG9tZXIgc2VjcmV0"}`.

   The header is caller-supplied. P4-2 disclosed it as a stand-in for the mTLS peer SVID, but until it is bound to a verified identity the route is an unauthenticated encryption and decryption oracle for any tenant.
2. **Anonymous tenant lifecycle.** `POST /api/v1/eap/tenants {"company_name":"kurasi"}` returns `201`, and `DELETE /api/v1/eap/tenants/6f82ad81` returns `200`, both with no token. None of the EAP routers (`tenant_isolation.py`, `environment_routing.py`, `webhook_triggers.py`) declares an auth dependency. Per P4-2's errata, teardown shreds the transit key, which would also make this anonymous destruction of customer data. The governor did not re-observe the shredding.
3. **The authz sweep went green by exemption.** Commit `13c87855` overwrote the 30-test cross-tenant sweep `tests/test_tenant_isolation.py`, and `afee7093` restored it.
   - Restored verbatim onto `13c87855`, the sweep **fails** and names all 14 new EAP/webhook routes as unchecked. The governor measured this directly: 1 failed, 108 passed.
   - `afee7093` got it to pass by adding those routes, plus the 2 transit routes, to `NOT_DATABASE_BACKED`. That declares them outside tenant-scoping checks, and the sweep's alarm is exactly what that silenced.
   - They should be in `DB_ROUTES` (or an equivalent tenant-scoped set) with real attack cases.
4. **The full fe-signalloom suite is red:** `1 failed, 1533 passed, 84 skipped`. `test_audit_provenance.py::test_every_mutating_route_makes_an_audit_decision` fails because 8 EAP mutating routes, tenant provision and teardown among them, neither audit nor declare an exemption.
5. **SVID delivery is not proven.** P4-2 finding F3: there is no SPIFFE CSI driver, and PSS `restricted` forbids the hostPath the SPIRE socket needs. Registration and minting are proven; a tenant pod fetching its SVID is not.
6. **Trust-domain mismatch.** Pattern 3 and the code default to `osramp.local`. The live SPIRE runs `signalloom.demo` and rejects `osramp.local` entries (P4-2 F1).
7. **Inert or misdirected egress** (P4-2 F2):
   - the `inf-bao:8200` egress allow is refused by `inf-bao`'s own default-deny
   - the engine targets a non-existent `inf-spire` namespace
8. **The board is not clean.** `kanban-check.sh doctor --shortcode SLET` exits 1:
   - 13 `done` cards have 0 output lines and no review or proof
   - P4-GOV itself shows state oscillation

   P0 through P4-1 have no commits of their own; every row cites `13c87855`. So "17 cards at 100% prompt-contract floor compliance" cannot be demonstrated.
9. **Commit convention.** 4 of the 6 SLET commits carry a scope (`feat(slet):`, `test(slet):`, `chore(P4-PRE):`), against the scope-less convention. They are recorded here and not rewritten, since rewriting would change SHAs that the errata already cite.
10. **Naming.** The proposal's P4-2 row and narrative say `kusari`, which hashes to `4b53ab6b`. The certified vector `6f82ad81` belongs to `kurasi`.

## Required before re-certification

- Bind transit and lifecycle routes to a verified identity, meaning a JWT tenant claim or an mTLS peer SVID, never a request header. Add negative tests for a forged `X-SPIFFE-ID`.
- Move the 16 EAP routes out of `NOT_DATABASE_BACKED` into a tenant-scoped sweep with attack cases.
- Write an audit event on every EAP mutating route, so the full suite goes green without new exemptions.
- Align the SPIFFE trust domain with the live SPIRE, and solve SVID delivery under PSS `restricted` (CSI driver).
- Re-run the zero-output P0–P4-1 cards so each carries its own commit and evidence.

## Reproduce

```bash
cd d2-signalloom/apps/fe-signalloom/src
UV_CACHE_DIR=/home/andy/src/.worktrees/.uvcache uv run --python 3.12 \
  --with pytest --with pytest-asyncio --with-requirements requirements.txt \
  python -m pytest tests -q -p no:cacheprovider
```

The anonymous-decrypt probe drives `TestClient(main.app)` in three steps:

1. `POST /api/v1/eap/tenants` for `kurasi`
2. `POST …/6f82ad81/transit/encrypt` with only a forged `X-SPIFFE-ID` header
3. `POST …/transit/decrypt` with the same header
