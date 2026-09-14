# SLDP mission certification — Signal Loom Production and Data-Protection Hardening

**Certified by:** SLDP-P6-GOV (Mission Governor) · **Date:** 2026-09-15
**Integration ref:** `refs/heads/integration/sldp-v0.1.0`
**Governor worktree:** `/home/andy/src/.worktrees/osramp-demo/sldp-v0.1.0/governor`
**Published contract:** [`sldp-downstream-contract.md`](./sldp-downstream-contract.md)
**Execution proof:** [`sldp-p6-gov-proof.md`](./sldp-p6-gov-proof.md)

---

## Verdict

**The mission CERTIFIES — with one headline property NARROWED, one control found uncompiled, and
the qualifications in §6.**

Nine mutations were applied across three rounds. **Eight were killed. One SURVIVED**, and it is the
most important result in this document:

> **Removing the tenant predicate from the subject-key store leaves
> `TestErasureSaga_ErasesOneSubjectOnly` green.** The test *asserts* cross-tenant isolation at
> `saga_test.go:158` and that assertion never fires, because the two tenants' pseudonyms are derived
> under different tenant keys and so cannot collide in a pseudonym-only match. **Cross-tenant
> erasure isolation is therefore NOT certified.** It is structurally plausible and empirically
> unfalsified. For a bank, that is the higher-severity half of the property.

What this changes:

| Headline property | Certified? |
|---|---|
| Erasure reaches one subject only — **within a tenant** | **YES** — 3 independent kills |
| Erasure reaches one subject only — **across tenants** | **NO** — M1d survived (§2) |
| Historical attestations still verify | **YES, narrowly** — positive and negative controls both live, but against writer-generated corpora, not golden pre-change bytes |
| Query p95 latency budget holds | **YES, at the enforced ceiling of 10 ms** — not at the 2.75 ms figure in circulation |

This verdict was reached only because the commitment-boundary advisor review asked whether all
three erasure kills were blind to the tenant predicate. They were. Rounds 1–2 had reported
7 mutations, 7 killed, and would have certified a property the suite does not defend. **A
falsification round that never produces a survivor has not finished.**

| Card | Merged at | Verdict |
|---|---|---|
| SLDP-P6-PRE | `086ac1f3` (recorded `ace7c954`) | **CERTIFIES** |
| SLDP-P6-1 | `c9ae419a`, merged `37830bba` | **CERTIFIES** |
| SLDP-P6-2 | `f9b08ace`, merged `a0429ea2` | **CERTIFIES** |

---

## 1. Headline properties — evidence, and the measurement conditions

**A figure without its conditions will be read as unconditional.** Each claim below is restated
with the conditions under which it was measured. Where a prior document states a different number,
both are given.

### Property 1 — Erasure reaches ONE SUBJECT ONLY

| | |
|---|---|
| **Claim, fully conditioned** | Erasing subject `alice` in tenant `t1` destroys every version of that subject's DEK, purges that subject's plaintext DEK cache entries, and leaves (a) a *neighbour subject* in the same tenant and (b) *the same subject name in another tenant* both still able to unwrap. Measured in the in-process `subjectkey` harness with a memory-backed key store; **not** measured against live PostgreSQL. |
| **Test** | `TestErasureSaga_ErasesOneSubjectOnly` — `si/subjectkey/saga_test.go:129` |
| **Result** | PASS (within `make test-signal-ingest`, EXIT 0) |
| **Why it is not vacuous** | The test asserts a **precondition** at `:136` that all three subjects start readable. Without it, "the target failed to unwrap" would be equally consistent with a broken key path and the test would pass for the wrong reason. |
| **Falsified by** | M1a, M1b, M1c — three independent mutations, all killed (§2) |
| **NOT falsified** | **M1d SURVIVED.** Dropping `r.TenantID == tenantID` from `MemoryStore.ListVersions` (`si/subjectkey/store.go:293`) leaves the test green. The cross-tenant assertion at `saga_test.go:158` never fires: `provision` derives the pseudonym via `Pseudonym(tenantID, subject)`, so `t1/alice` and `t2/alice` have different pseudonyms and a pseudonym-only match cannot collide. The test **is** two-tenant with a colliding subject *name* — it is the pseudonym, not the test, that provides the isolation, and nothing tests the predicate. |
| **Consequence** | **Intra-tenant per-subject isolation: CERTIFIED. Cross-tenant isolation: NOT CERTIFIED.** The remedy is a test that provisions two tenants whose key records share a pseudonym value, asserts the pre-state row count (a claim-less query under FORCE RLS returns zero rows and passes vacuously), erases in A and asserts B survives — then re-runs M1d and requires red. That is implementation work and is handed to the next phase, named in §7. |

### Property 2 — Historical attestations STILL VERIFY

| | |
|---|---|
| **Claim, fully conditioned** | The mission's privacy changes did not invalidate previously-signed evidence, because erasure is crypto-shredding plus tombstones and never rewrites attested bytes; segment schema v2 shipped as a new schema version, and the segment schema is separate from the attestation schema. Verified against corpora generated by the writer in `t.TempDir()` fixtures, using local and mock-KMS signers; **not** verified against a live deployment's evidence directory. |
| **Tests** | `TestVerifyCorpusGeneratedByWriter` (`si/store/segment_verifier_test.go:198`); `TestSegmentSchema_IsNotTheAttestationSchema` (`si/store/segment_schema_v2_test.go:146`); `TestSigner_KMS_Rotation_And_DestroyedKey_VerificationWithRetainedPublicMaterial` (`si/store/signer_test.go:390`) |
| **Result** | PASS (all within `make test-signal-ingest`, EXIT 0) |
| **Why it is not vacuous — both directions** | A verifier that accepted everything reports "verifies" identically; a verifier that *rejected* everything would fail the property while both rejection tests stayed green. Both directions were therefore probed. **Negative:** M2a/M2b disable the verifier's discrimination and the rejection tests go red. **Positive (M2c, added after advisor review):** inverting the digest comparison so valid segments are *rejected* turns `TestVerifyCorpusGeneratedByWriter` red. The verifier both accepts valid evidence and refuses invalid evidence, and each half can fail. |
| **Falsified by** | M2a, M2b, M2c — all killed (§2) |
| **Residual gap, stated plainly** | Every corpus is generated by the **current** writer inside `t.TempDir()`. There is **no golden attestation produced by a pre-change binary checked into the tree**. A change to canonicalisation, field ordering in the digest preimage, or envelope schema version would break backward compatibility with real historical evidence while every named test stayed green, because the fixtures would be regenerated in the new format. **"Historical" is certified as "the writer's own corpus, including segments the fixture marks historical" — not as "bytes signed by an older build".** Closing it needs a checked-in golden corpus; that is implementation work, handed to the next phase (§7). |

### Property 3 — Query latency budget HOLDS

**This is the claim most at risk of being read as unconditional, so it is stated three ways.**

| Figure | What it actually is | Conditions |
|---|---|---|
| **2.75 ms** | The *originally published* p95. It is an artefact of **SFDP-P4-3, a different mission**, recorded `2026-09-05T22:48:15+01:00` on an AMD Ryzen 9 7900X, 100 iterations. `si/store/frostdb_p95.json`. | Inherited constant, not re-measured by SLDP |
| **2.19 ms** | SLDP-P3-GOV's re-measurement of the same test. `sldp-p3-governor-proof.md:31,166`. | Different machine/run |
| **2.096 ms** | **This certification's measurement**, 2026-09-15, `TestFrostDBStore_K8sAudit_VolumeBenchmark_P95`, N = 12,000 observations across 24 hourly partitions, seed 42, 100 iterations, selective pushdown query (1-hour window + layer + actor), selectivity 160/12,000 = 1.33%, `-tags frostdb`, CGO disabled. | The conditioned claim |
| **10.0 ms** | **The figure actually enforced.** `P95GuardCeiling` at `si/store/frostdb_test.go:1544`. | The regression gate |

| | |
|---|---|
| **What is CERTIFIED** | **Store-level query-path p95 ≤ 10 ms**, measured in the Go benchmark harness at N = 12,000, single-threaded, on this CI-class host. That is the enforced claim, because 10 ms is the only threshold any test asserts. |
| **What is MEASURED but not enforced** | 2.096 ms under the conditions in row 3. |
| **What is NOT certified** | "p95 ≤ 2.75 ms", and any deployment-level SLO. A benchmark p95 at a fixed dataset and zero concurrency is not a production service-level objective and must not be quoted as one. |
| **Tests** | `TestFrostDBStore_K8sAudit_VolumeBenchmark_P95`; `TestFrostDBStore_K8sAudit_VolumeBenchmark_RegressionGuard` (p95 1.922 ms, 50 iterations); `TestFrostDBStore_VolumeBenchmark_PruningAndP95` (pushdown p95 1.369 ms) |
| **Result** | PASS — `go test -tags frostdb -run 'P95\|VolumeBenchmark\|Pruning' ./store/...` EXIT 0 |
| **Falsified by** | **M3b is the load-bearing kill** — it slows the *real* query path by disabling predicate pushdown and the guard goes red at 13.25 ms. M3a (a 12 ms sleep) also kills, but it is a **timer sanity check, not a property test**: a sleep sized above the gate kills any latency assertion and shares a constant with the thing it is testing. Its only genuine contribution is isolating Hard Gate 1 from Hard Gate 2 by holding selectivity at 1.33%. Recorded as such rather than counted as independent evidence. |

**Qualification Q1 (see §6).** Two numbers coexist — 10 ms enforced, 2.75 ms quoted — and the
coexistence is *how* a 3.6× gap survived six phases of review. A regression from 1.92 ms to 9.9 ms
ships green. **The headline above has been restated to the enforced value rather than filing the
gap as a footnote on an otherwise-certified 2.75 ms claim**, because filing it that way would
invert which number is the property.

**Qualification Q2 (see §6).** Every latency test carries `//go:build frostdb`. `make
test-signal-ingest` — the target named in this card's required-test list — **does not run any of
them**. The latency property was certified only because this governor ran the tagged suite
separately. The same is true of the telemetry allow-list (`si/store/label_allowlist.go` is
`//go:build frostdb`).

---

## 2. Falsification — proof the certification can fail

Method: for each property, establish a positive control (the named test passes unmutated), then
remove the property from **production** code and require an observed `--- FAIL: <TestName>` line.
A mutation that does not apply, does not compile, or produces a non-zero exit without a matching
FAIL line is reported **INCONCLUSIVE**, never as a kill. Every mutation is reverted by the harness,
which runs in a dedicated detached worktree so the governor tree is never touched.

Harness: `falsify.sh`, `falsify2.sh` (reproduced in the execution proof). Logs:
`/tmp/sldp-p6gov-falsify/`.

| ID | Property removed | File mutated | Test | Verdict | Observed failure |
|---|---|---|---|:---:|---|
| M1a | per-subject cache scope | `subjectkey/cache.go:187` `PurgeSubject` prefix → `""` | `TestErasureSaga_ErasesOneSubjectOnly` | **KILLED** | `saga_test.go:166: the neighbour's cached keys were purged too; PurgeSubject is not subject-scoped` |
| M1b | tenant component of cache scope | same site, tenant dropped from prefix | same | **KILLED** | `saga_test.go:143: plaintext key cache still holds entries for the subject after purge; erasure would be cosmetic: 2 entries remain` |
| M1c | per-subject key-destruction scope | `subjectkey/saga.go:299` `ListVersions(ctx, tenantID, "")` | same | **KILLED** | `saga_test.go:143: Erase: subjectkey: list key versions: subject pseudonym is required` |
| M2a | segment digest binding | `store/verify/verify.go:457` comparison disabled | `TestVerifyRejectsTamperedSegment` | **KILLED** | `segment_verifier_test.go:253: expected digest rejection, got <nil>` |
| M2b | checkpoint chain continuity | `store/verify/verify.go:499` → `return nil` | `TestVerifyRejectsBrokenCheckpointChain` | **KILLED** *(see note)* | `segment_verifier_test.go:343: expected chain rejection, got checkpoint sequence 2: checkpoint signed subject digest differs from predicate` |
| M3a | p95 latency ceiling | `store/frostdb.go` — 12 ms sleep in `QueryRange` | `..._RegressionGuard` | **KILLED** | `p95=14.067381ms (ceiling=10ms), selectivity=1.33%` → `REGRESSION: ... exceeded guard ceiling` |
| M3b | pushdown / row-group pruning | `store/frostdb.go:462` filter application disabled | `..._RegressionGuard` | **KILLED** | `p95=13.250596ms, selectivity=100.00%` → same gate |
| **M2c** | verifier's ACCEPTANCE of valid evidence (digest comparison inverted) | `store/verify/verify.go:457` `!=` → `==` | `TestVerifyCorpusGeneratedByWriter` | **KILLED** | a valid corpus is rejected; the positive control is live |
| **M1d** | tenant predicate in the key store | `subjectkey/store.go:293` `r.TenantID == tenantID &&` removed | `TestErasureSaga_ErasesOneSubjectOnly` | **SURVIVED** | **mutant still green — the cross-tenant assertion at `saga_test.go:158` does not defend the predicate** |

| **M1e** | tenant predicate — **whole-package blast radius** | same site as M1d | **every test in `./subjectkey/...`, `./privacy/...`, `./privacy/tombstone/...`** | **SURVIVED** | all three packages report `ok`. Mutant liveness proved by `grep -c 'r.TenantID == tenantID && r.SubjectPseudonym'` → **0** in the built source |

**10 mutations: 8 killed, 2 SURVIVED, 0 inconclusive at final state.**

**M1e is the finding, and it is worse than M1d.** M1d showed one test blind to the tenant predicate.
M1e widened the probe from a single test to every test in the three packages that own erasure,
privacy and tombstones — **and not one of them notices the predicate being deleted.** The whole
erasure test surface is blind to it, so this is not a gap in one assertion that a better assertion
would close; it is an untested control. The mutant's liveness was proved independently rather than
inferred: the predicate is absent from the source that was compiled (`grep -c … → 0`).

This probe was run because the two commissioned external audits could not execute (proof §8) and the
survivor was produced by a harness written quickly under budget pressure. Widening the blast radius
was the cheapest available substitute for an independent reviewer, and it found more than the
reviewer had been asked to check.

M2c and M1d were added in round 3, commissioned by the commitment-boundary advisor review, which
asked two questions rounds 1–2 had not: *are all your Property-2 kills rejection tests, so a
verifier that rejects everything would pass?* and *are all your Property-1 kills blind to the tenant
predicate?* The answers were yes and yes. M2c closed the first. M1d confirmed the second and is the
survivor.

**Note on M2b — the kill is real but the attribution is imprecise, and the distinction is the
interesting part.** The test went red, so `TestVerifyRejectsBrokenCheckpointChain` is unambiguously
live. But it did not fail with "chain rejection missing"; it failed with *a different rejection* —
the subject-digest-versus-predicate check at `verify.go:487` fired first on the same fixture. So
what M2b actually establishes is **"a broken chain is caught, and the checkpoint path has at least
two independent checks"**, not "the continuity check at `:499` is the sole defender of chain
integrity". A single-control reading of that line would be wrong. Recorded rather than smoothed
over, because a mutation killed by a *substitute* control is exactly the shape that lets a real
single-point regression hide behind a green suite.

**M3a is the discriminating latency kill.** Selectivity stayed at **1.33% — unchanged from
baseline** — so Hard Gate 2 (pruning) could not have fired. Only Hard Gate 1, the p95 ceiling
assertion itself, could produce that failure. The latency assertion is live, not decoration.

**Two round-1 INCONCLUSIVEs, recorded because the distinction matters.** M1a/M1b first reported
INCONCLUSIVE from a genuine ambiguity — `prefix := subjectPrefix(tenantID, pseudonym)` occurs at
both `cache.go:168` (`SubjectKeys`) and `:187` (`PurgeSubject`). M3b reported INCONCLUSIVE from a
**harness defect**: `grep -F -c` on a multi-line literal counts *lines matching any constituent
line*, not occurrences of the literal, so it returned 2 for a site occurring once. Both were fixed
in round 2 by anchoring on the enclosing function signature and by computing occurrence counts in
Python over the whole string. **In both cases the guard failed safe** — it refused to write and
reported INCONCLUSIVE rather than mutating the wrong site and reporting a kill.

**What the falsification does NOT prove — stated so it is not inferred.** None of M1a/M1b/M1c
fails at `saga_test.go:158`, the cross-tenant assertion ("the same subject name in ANOTHER tenant
lost access"). M1a fails at `:166` (neighbour), M1b and M1c at `:143` (fail-closed self-check). The
cross-tenant assertion is arguably unfalsifiable by cache-scope mutation *by construction*, because
the two tenants' pseudonyms are derived under different tenant keys and therefore cannot collide in
a prefix match. That is a strong structural argument for the property and a weak empirical one.
**Cross-tenant erasure isolation is accepted on construction, not proven by falsification.**

---

## 3. Reconciled boundary map — every verdict that changed

SLDP-P0 (`sldp-p0-boundary-map.md`, evidence revision `a5de2461`) recorded the baseline. Every
verdict below was re-probed in the governor worktree at `bd254546`.

| Primitive | P0 verdict | Verdict now | Changed by | Evidence probed today |
|---|---|---|---|---|
| signal-ingest HTTP authentication | **ABSENT** — bare `http.NewServeMux()`, no middleware | **EXISTS** | P1-1 | `si/api/auth.go` route table binds every route to a permission; e.g. `:322-323` |
| Encryption writer fail-closed | **PARTIAL** — `NewEncryptorFromKeyString("")` returned a passthrough | **EXISTS** | P1-2 | `si/identity/encryption_test.go:127` `TestNewEncryptorFromKeyString_ProductionRefusalOnEmptyKey` |
| Go `SegmentAttestor` verification entrypoint | **ABSENT — expected future seam** | **EXISTS** | P1-3 | `si/store/verify/verify.go:176` `VerifyCorpus`, `:237` `VerifySegment` |
| HMAC anonymiser in a production path | **PARTIAL** — `AnonymizeHMAC` existed, no production caller | **EXISTS** | P2-1, P3-1 | `si/store/segment_pseudonymiser.go:138`; write path drops cleartext (`segment_schema_v2_test.go:310`) |
| Tenant isolation / row-level security | **ABSENT** — 0 × `ENABLE ROW LEVEL SECURITY`, 0 × `CREATE POLICY` repo-wide | **EXISTS** | P2-2 (+ 007/008/009/010) | `006_tenant_isolation_rls.sql`: 4 × enable, 8 × policy, session var `app.current_tenant:40`; live proof `make test-identity-rls-live` |
| Secret scrubber at every persistence boundary | **PARTIAL** — type existed, collectors bypassed it | **EXISTS (keys)/PARTIAL (values)** | P3-1 | `si/store/label_allowlist.go` — 48-key closed allow-list; **values remain unconstrained free text** (source, `:49-55`) |
| Erasure / deletion / retention code | **ABSENT** — zero `DELETE FROM`; `EventPartitionDropped` had 0 call sites | **EXISTS** | P3-2, P4-1, P6-1 | `si/privacy/`, `si/subjectkey/`, `si/retention/`; `EventPartitionDropped` now called from `privacy/erasure.go` (1) and `retention/controller.go` (2) |
| Per-subject key hierarchy | **ABSENT** | **EXISTS** | P4-1 | `si/subjectkey/hierarchy.go:121,165,248,343`; `009_subject_keys.sql` |
| Attestation revocation / tombstones | **ABSENT — expected future seam** | **EXISTS** | P4-2 | `si/privacy/tombstone/{tombstone,signer}.go` |
| Non-exportable KMS signing | **not in P0 scope** | **EXISTS** | P5-1 | `si/store/signer_kms.go:63` `NewKMSSigner` |
| Article 15 / 20 data-subject rights | **ABSENT** | **EXISTS** | P5-3 | `si/api/auth.go:321-323` routes gated by `PermissionPrivacyExport` |
| Article 21 objection | **ABSENT** | **PARTIAL** | P5-3 | registration/persistence exist; **no server-side enforcement** (P5-GOV finding G4) |
| Article 18 restriction | **ABSENT** | **ABSENT** | *nobody* | `rg 'frozen' si/identity/` → zero lines. No board row owns it. |
| Retention receipts across every sink | **ABSENT** | **EXISTS** | P6-1 | `si/retention/sink.go:205` `AllSinkSpecs()` → **35** entries (probe-counted); `010_retention_receipts.sql` |
| Delegation revocation | **EXISTS** | **EXISTS** *(unchanged)* | — | `si/api/revocation_handler.go`, `identity/repository.go:320-368` |
| Segment attestation (signing/checkpointing) | **EXISTS** | **EXISTS** *(unchanged, signer abstracted)* | P5-1 | `si/store/segment_attestor.go` + `signer.go` |
| Python `audit_anchor` verification | **EXISTS** | **EXISTS** *(unchanged)* | — | `fe-signalloom/src/audit_anchor/{segments,cli}.py` |

**14 verdicts changed. 3 unchanged. 1 (Article 18) still ABSENT with no owner.**

**The most consequential change is not in the table: the denominator.** P6-1 re-derived the
storage-copy inventory and found P6-PRE listed 23 rows, P0 listed 21, and **neither was a subset of
the other** — P0 held nine copies the reconciliation dropped. The union plus three card-named copy
classes is **35**. This matters because a forgotten sink does not present as a hole; it lowers the
denominator and presents as *higher* coverage, and the overdue gauge iterates the enumerated set,
so a copy never enumerated can never go overdue. The strongest correcting loop in the design was
blind to precisely the failure that defeats it. `inventory_parity_test.go` now derives its
expectation by parsing both source documents, which flips the sign of that loop.

---

## 4. Required tests

| Command | Result |
|---|---|
| `make test-signal-ingest` | **EXIT 0** — 28 packages `ok`, 1329 `--- PASS`, 0 `--- FAIL` |
| `cd d2-signalloom/apps/signal-ingest && go test ./...` | **EXIT 0** — same 28 packages (the make target wraps it) |
| `bats test/acceptance-spec-coverage.bats` | **EXIT 0** — 7/7 `ok`, 0 `not ok` |
| `make demo-signalloom-api-test TIER=contract` | **EXIT 0** — 56 passed |
| `go test -tags frostdb -run 'P95\|VolumeBenchmark\|Pruning' ./store/...` | **EXIT 0** — p95 2.096 ms @ N=12,000 |
| `scripts/kanban-check.sh doctor --repo … --shortcode SLDP` | **EXIT 1** — 1 exception, **SLDP-disjoint** (§6, Q3) |

---

## 5. Errata completeness — probe-derived

Counted by parsing the reviewed plan's Work Decomposition role table and the Appendix errata
headings, **not** by reading a hand-written total.

```
cards in Work Decomposition (role table): 28
  P0 P1-PRE P1-1 P1-2 P1-3 P1-GOV P2-PRE P2-1 P2-2 P2-3 P2-GOV
  P3-PRE P3-1 P3-2 P3-GOV P4-PRE P4-1 P4-2 P4-GOV
  P5-PRE P5-1 P5-2 P5-3 P5-GOV P6-PRE P6-1 P6-2 P6-GOV
errata blocks: 29 | distinct cards covered: 28
cards with NO errata block: NONE
duplicate errata blocks:    ['P6-1']   (a `(bootstrap)` stub plus the real block)
rows with Pending Result:   ['P6-GOV'] (this card, filled on completion)
```

**Every card in the mission has an errata entry.** The P6-1 duplicate is a bootstrap stub left in
place rather than altered, per the shared-file rule (append only; never modify a prior entry).

**Scope of this claim, stated precisely:** 28/28 cards have a *mapped* errata block. The probe
checks existence and card-ID association. **It does not check that any block's content is correct**;
no machine check exists for that, and none was written. Contents were read in full for P5-GOV,
P6-PRE, P6-1 and P6-2 (four cards) while assembling §1, §3 and §7; the other twenty-four were
matched by heading only.

Note the board's `progress` listing truncates and shows only 25 of the 28 SLDP cards, so it is not
a safe enumeration source. The Work Decomposition table is.

Note the board's `progress` listing truncates and shows only 25 of the 28 SLDP cards, so it is not
a safe enumeration source. The Work Decomposition table is.

---

## 6. Qualifications on this certification

**Q1 — The enforced latency ceiling is 5.2× the measured value.** `P95GuardCeiling = 10ms`
(`si/store/frostdb_test.go:1544`) against a measured 1.92 ms. The guard defends "pushdown has not
been lost". It does not defend the 2.75 ms figure that circulates as the budget. **Recommendation:**
either tighten the ceiling to a documented multiple of the measured value, or stop quoting 2.75 ms
as a protected number. Not fixed here — changing a threshold is an implementation decision outside
a governor's role boundary.

**Q2 — the telemetry allow-list is not merely untested, it is not TYPE-CHECKED.** Upgraded from a
qualification to a finding after advisor review. `si/store/label_allowlist.go` carries
`//go:build frostdb`, and **`-tags frostdb` appears exactly once in the entire Makefile**
(`test-signal-ingest-frostdb`, line 572) and **nowhere under `.github/`**. Probed, not assumed.

So `go build ./...`, `go vet ./...` and `make test-signal-ingest` all skip the file entirely. It can
reference a deleted field, drift from its source of truth, or silently gain a 49th key, and every
default lane stays green. **For a control whose job is to bound what leaves a bank's estate, "not
compiled by any required lane" is closer to absent than to qualified.**

The decisive question, and it is answerable in one command by whoever owns the fix: *does adding a
new telemetry key fail anything in a lane that actually runs?* Today the answer is no. The cheap
remedy is that the allow-list is **data** — it needs no FrostDB — so the assertion can move to an
untagged test. Not done here; a governor does not restructure build tags.

The same tag covers every latency test, which is why the latency property had to be certified by a
suite this governor ran by hand rather than by the card's own required-test list.

**Q3 — `doctor` exits 1, and it is not an SLDP defect.** The single exception is a board-wide
FAST-EXIT/AGENT-CRASH check listing 29 tasks. **Proved SLDP-disjoint:** the 29 task IDs were
extracted and intersected with the SLDP card list and with the full SLDP board dump — the
intersection is empty in both directions. The tasks belong to `cpai-opencode*`, `antigravity`
`__home_agent__` pseudo-tasks, and two literal `test-*` fixture cards. Remediating tasks owned by
other boards is outside this card's scope ("Do not touch these. Each is owned by another card").
**The required evidence "zero exceptions for the SLDP shortcode" is therefore satisfied in
substance and NOT in the exit code, and this certification says so rather than claiming green.**

---

## 7. Passed downstream unresolved

Inherited from SLDP-P5-GOV §4 and re-confirmed as still open, plus items this card adds. Named
explicitly so the next phase inherits them by statement rather than by omission.

1. **Article 18 (restriction of processing) has no owner on any board row.** The `frozen` actor
   status the GDPR reference claims exists does not.
2. **Article 21 has no server-side enforcement** (P5-GOV G4). Host-sensor objection registry is
   process-local and in-memory; no deletion controller reaches workstation sensor memory.
3. **Cross-tenant isolation on the Article 15/20 export path was never assessed** (P5-GOV G1). The
   export harness is not tenant-scoped.
4. **17 of 19 failing DPIA checklist rows need a controller, lawyer, DPO or operations owner**, not
   engineering. They cannot be closed by this board and must not be represented as engineering debt.
5. **Article 36 prior consultation is REQUIRED on current evidence**, with an 8+6 week clock on the
   deployment critical path.
6. **Works-council instruments OPEN-13 (DE), OPEN-14 (FR), OPEN-15 (NL) are not started.** DE and NL
   are veto/consent gates — deployment in those jurisdictions is blocked until executed.
7. **Segment-attestor queue-overflow posture is undecided.** A KMS-induced overflow still leaves a
   segment silently unattested with `Upload` returning `nil`.
8. **NEW — free-text label VALUES are unconstrained.** The allow-list bounds keys only; `reason`
   routinely holds strings like `User "alice" cannot get pods`. No redaction is in force.
9. **NEW — Q1 above.** The gap between the enforced ceiling and the quoted budget.

Handed to this governor explicitly by SLDP-P6-1 and **not closed here**, because each is an
implementation or policy decision outside a governor's role boundary:

10. **Retention receipts prove intent, not effect.** There is no post-purge negative read-back; the
    purger supplies its own counts. A purger that silently removed nothing would produce a
    `purged` receipt.
11. **There is no per-sink retention FLOOR.** Only ceilings exist. Premature destruction of
    MiFID/AML/SOX records is a larger bank exposure than late deletion, and `min <= max` per sink
    is a policy decision nobody has taken.
12. **`audit.EventPartitionDropped` is overloaded.** It now means both "an Article 17 erasure
    decision was permitted" (`privacy/erasure.go`) and "a retention sweep dropped a partition"
    (`retention/controller.go`), writing one `signal_audit_trail.event_type` value. Mitigated for a
    reader by `"cause":"retention"` in the detail payload; the durable fix is a distinct event type
    with a widened CHECK constraint.
13. **The P0 inventory parity join keys on a verbatim document string**, not a stable ID. Reformat
    either source document and the parity test breaks for a cosmetic reason.
14. **Eleven of the 35 sinks have no in-process purger** and go overdue by day 3 by design. The
    gauge carries a `reach` label so this reads as a dated gap rather than a failure, but the gap
    is real and owned by no card.

---

Added by this governor, ranked by severity for a regulated deployment:

15. **HIGHEST — cross-tenant erasure isolation is unfalsified (M1d survived).** Needed: a test
    where two tenants' key records share a pseudonym *value*, with an asserted pre-state row count,
    that goes red when the tenant predicate is removed. Under `FORCE ROW LEVEL SECURITY` a
    claim-less query returns zero rows rather than erroring, so a test without a pre-state
    assertion passes vacuously. Run `-p 1` if the package shares a database.
16. **The telemetry allow-list needs a required lane** (Q2). Either move the assertion to an
    untagged test or make a `-tags frostdb` job required rather than absent.
17. **No golden pre-change attestation corpus exists.** Property 2 cannot detect a
    backward-compatibility break.
18. **`P95GuardCeiling` is 5.2× the measured value** (Q1). Tighten it, or stop quoting 2.75 ms.
19. **M2b's removed line is not proven load-bearing.** It was killed by a substitute control
    (`verify.go:487`). Either it is redundant — in which case the *substitute* is the enforcement
    point and the contract should name that one, since siblings will build against whatever is
    named — or an input exists where only `:499` fires and no test supplies it.
20. **The doctor lane's signal is already spent.** It exits 1 today on other boards' crashed tasks,
    so a *future* SLDP failure will be masked by the pre-existing red. An SLDP-scoped invocation
    that can exit 0 is needed for the lane to mean anything.
21. **Article 18's absence was NOTICED, not derived.** No enumeration of in-scope GDPR articles was
    run against the implementation, so it is unknown what else is missing. Article 18 is also not
    orthogonal to Property 1 — a restriction flag must suppress processing as well as deletion, and
    no erasure evidence reaches that.

## 8. Assumed rather than tested

Stated so a later reader can tell a proven property from an accepted one.

1. **Cross-tenant erasure isolation is UNFALSIFIED** (§2, M1d). Not "accepted on construction" —
   that phrasing reads as a certification tier and it is not one. The structural argument (tenant-keyed
   pseudonyms cannot collide) is sound but untested; the predicate that would enforce it if the
   argument ever failed is provably undefended.
2. **Nothing was probed against a live deployment.** All evidence comes from Go and Python test
   harnesses and from static probes of the governor worktree at `bd254546`. Per the card's
   out-of-scope rule, no live customer infrastructure was contacted.
3. **Erasure isolation was measured against the in-process memory key store**, not against live
   PostgreSQL. `subjectkey/postgres_live_test.go` exists but was not separately invoked by this
   card; it is covered only insofar as `go test ./...` reaches it.
4. **FrostDB physical Parquet unlinking remains unconfirmed.** `DropPartition` advances an
   in-memory cutoff and unlinks nothing.
5. **PostgreSQL WAL and physical-backup residuals are a confirmed limitation, not a defect.**
   Receipts declare `StorageResidualMVCCAndBackup` rather than claiming bit-level erasure.
6. **The mock KMS `DESTROYED` state was never compared against real Cloud KMS semantics.** It does
   not change the verdict — the production verify path never calls `GetPublicKey` — but the test's
   "destroyed" may be weaker than reality. Inherited unresolved from P5-GOV.
7. **The three merged P6 commits were certified from their proof documents plus a re-run of the
   full suite**, not by re-deriving each card's internal findings from scratch.
