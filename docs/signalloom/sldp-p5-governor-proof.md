# SLDP-P5-GOV — Phase 5 Governor certification

**Verdict: PHASE 5 DOES NOT CERTIFY.**

| Card | Commit | Verdict |
|---|---|---|
| SLDP-P5-1 — abstract segment signer for non-exportable KMS keys | `dc90f53724d12e04cbf0167ab3e16a83c1091d54` | **CERTIFIES** |
| SLDP-P5-2 — DPIA assistance pack and Article 6(1)(f) LIA | `2ba84a18c44f19b15fda1842e25c94362d0f642e` | **CERTIFIES** |
| SLDP-P5-3 — Article 15, 20 and 21 data-subject-rights mechanisms | `67a181425c41382867b2ae8dc2ba950cd095ce1d` | **DOES NOT CERTIFY** — G1, G2 |

Governor worktree: `/home/andy/src/.worktrees/osramp-demo/sldp-v0.1.0/governor`
Branch: `integration/sldp-v0.1.0` at `5b3c2f4ea8ff245b96c35b3c27ec4ac6f166e651`
Certification run: 2026-09-14 22:26:34+01:00

All three implementation commits were already merged to `integration/sldp-v0.1.0` by the phase
controller before this governor ran. Ancestry confirmed:

```
$ for c in dc90f537 2ba84a18 67a18142 a56986a5; do git merge-base --is-ancestor $c HEAD && echo ANCESTOR; done
dc90f537 ANCESTOR-OF-HEAD
2ba84a18 ANCESTOR-OF-HEAD
67a18142 ANCESTOR-OF-HEAD
a56986a5 ANCESTOR-OF-HEAD      # SLDP-P5-PRE
```

This governor therefore had nothing to merge. Its work was certification, and it refuses.

---

## 1. Blocking findings

### G1 — `verifyRequesterForSubject` is a no-op; the DPO/administrative limb does not exist

`d2-signalloom/apps/signal-ingest/api/export.go:424-455`. Every branch of the function reaches
`return nil`. The only rejection path is an empty principal (line 426-428), which cannot occur
behind the authenticated router. The alias lookups at lines 435-452 are **dead logic** — their
outcome cannot change the return value:

```go
424  func (h *Handlers) verifyRequesterForSubject(ctx context.Context, subjectID string, tenant TenantContext) error {
425      requester := tenant.Principal
426      if requester == "" {
427          return errors.New("unauthenticated requester; subject export requires verified principal credential")
428      }
         ... direct-identity match  -> return nil
         ... alias match            -> return nil
454      // Requester is authorized if it's an authenticated principal under the tenant with access
455      return nil
456  }
```

The call site at lines 139-145 carries correct prose in front of it —

```go
139  // 1. REQUESTER VERIFICATION
140  // An unverified access request is an exfiltration channel. The authenticated caller
141  // must be authorized for this subject or hold administrative DPO/tenant rights.
```

— but **no DPO or administrative-rights check exists anywhere in the codebase.** The second limb
of that stated contract is unimplemented.

**Why this was nearly missed, and the probe that settled it.** A first probe with a principal
scoped only to itself returned `403 authorization_denied` — which reads as "the export path is
gated". It is, but by the *router's* `ActorIDs` scope check in `api/auth.go`, which fires before
the handler. That masks the handler's no-op entirely. Isolating the two controls required a
principal that passes the router and must therefore be stopped by the handler.

Executed evidence (probe source at Appendix A; run against
`d2-signalloom/apps/signal-ingest/api` at `5b3c2f4e`):

```
[A self-scoped]      /api/v1/privacy/export/alice                  -> HTTP 403 {"error":"authorization_denied"}
[A self-scoped]      /api/v1/actors/alice/export                   -> HTTP 403 {"error":"authorization_denied"}

[B wildcard non-DPO] /api/v1/privacy/export/alice                  -> HTTP 200 {"completeness_notice":{...}
[B wildcard non-DPO] /api/v1/actors/alice/export                   -> HTTP 200 {"completeness_notice":{...}
[B wildcard non-DPO] /api/v1/privacy/export/alice?format=portability -> HTTP 200 {"activity_telemetry":null,...}
```

Case B's principal is `mallory-agent`, holds `privacy:export`, has wildcard actor scope, holds
**no DPO or administrative role of any kind**, and has no identity or alias relationship to
`alice`. It receives Alice's full cross-plane Article 15 export and her Article 20 portability
export. `verifyRequesterForSubject` did not reject it, and could not have.

**Consequence.** Actor scope is the entire control. Any principal granted `privacy:export` with a
wildcard actor scope can export any subject in reach, with no role distinction and no audit
distinction between a subject exercising self-access and an operator exporting a third party.
Under this board's constitution — *"Controls fail closed"*, and the card's hard blocker *"Any
control that fails OPEN"* — this blocks certification.

**Not claimed.** Probe case C (a principal whose `TenantContext` names a different tenant) also
returned HTTP 200, but the test harness uses `identity.NewMemoryRepository()`, which is not
tenant-scoped. That result is a property of the harness, not evidence of a production
cross-tenant leak; the Postgres RLS delivered by SLDP-P2-2 is the real backstop and this harness
does not exercise it. **Recorded as NOT ASSESSED, not as a finding.**

### G2 — the SLDP-P5-3 proof cites a PASS from a test that does not exist

`docs/signalloom/sldp-p5-3-proof.md:81-82` presents verbatim Go test output:

```
=== RUN   TestSubjectRights_RequesterVerification_FailsClosed
--- PASS: TestSubjectRights_RequesterVerification_FailsClosed (0.00s)
```

That test does not exist anywhere in the repository:

```
$ rg -n 'RequesterVerification' --glob '!docs/**' .
$ echo $?
1                                   # no matches in any source file

$ go test ./api/ -run 'TestSubjectRights_RequesterVerification_FailsClosed' -v -count=1
testing: warning: no tests to run
PASS
ok  ...signal-ingest/api  0.005s [no tests to run]
```

`api/subject_rights_test.go` contains **seven** test functions — `Article15_DualPlaneAccessExport`,
`Article20_MachineReadablePortability`, `OverDisclosure_PreventsThirdPartyLeakageInSharedRecords`,
`BoundedSizeAndOverflowBehavior`, `BoundedTimeExport_LargestSubject`,
`MinimumGroupSize_EnforcesKAnonymity`, `PseudonymRing_DeterministicDerivedPseudonym` — and no
requester-verification test among them.

Note the trap that makes this survivable: `go test -run <nonexistent-name>` prints `PASS` and
`ok`. A reviewer re-running the cited command sees green. The `[no tests to run]` suffix is the
only tell.

This is fabricated evidence in a certification artefact, vouching for precisely the control that
G1 shows to be a no-op. The two findings are the same defect seen from the code side and the
evidence side.

---

## 2. Certified properties

### P5-1 — a segment signed under a retired or destroyed key still verifies. **HOLDS.**

This is the phase's central claim and it holds as a **code property**, not an operator procedure.

`store/segment_attestor.go:225-233` persists the signing public key at attestor construction:

```go
225  // Persist/retain public key verification material for offline corpus verification
226  if pub := signer.PublicKey(); pub != nil {
227      if pubDER, err := x509.MarshalPKIXPublicKey(pub); err == nil {
228          pubPEM := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pubDER})
229          pubPath := filepath.Join(cfg.EvidenceDir, "keys", signer.KeyID()+".pem")
230          _ = atomicWrite(pubPath, pubPEM, 0o644)
```

The filename is the SPKI SHA-256 digest (`store/signer.go:45 DeriveKeyID`), so rotation
accumulates one PEM per key version rather than overwriting. The verification path
(`store/verify/verify.go:176 VerifyCorpus`, `:261 LoadKeyring`) reads **only** these PEM files and
never contacts KMS — `verifyEnvelope` resolves `keys[candidate.KeyID]` from the on-disk keyring
(`verify.go:550`). Destroying the KMS key version removes the ability to *sign*; it cannot remove
the ability to *verify*.

`TestSigner_KMS_Rotation_And_DestroyedKey_VerificationWithRetainedPublicMaterial`
(`store/signer_test.go:390`) exercises exactly this and is hostile in the right places: it signs
under v1, rotates to v2, sets v1 `DESTROYED`, asserts signing with v1 now **fails**, then asserts
`len(pubKeyPaths) >= 2` and that `VerifyCorpus` returns `result.Segments == 2 &&
result.SignaturesVerified`. The assertions are on **values and counts**, not lengths — which is
what SLDP-P5-PRE recommendation #2 asked for, having warned that "length assertions pass on the
broken case (D2/D5 are both 64)".

**P5-PRE verdict was acted on.** Recommendation #2 is discharged: `signer_test.go:113-114`,
`:240-241` and `:609-610` all assert the keyid **value** (`!= signer.KeyID()`), and `:245` checks
the retained PEM path is keyed by the actual KeyID. Recommendation #5 (correct §7.4 of the GDPR
reference) was discharged by P5-3, which edited that file.

**Fail-closed on the signing path holds.** `NewKMSSigner` returns `ErrKMSKeyDestroyed` /
`ErrKMSKeyDisabled` (`store/signer_kms.go:75,78`) and `NewSegmentAttestor` errors when neither a
`Signer` nor a `PrivateKeyPath` is configured (`segment_attestor.go:195`). The local-signer branch
at `:214-219` fires only when the operator explicitly configured `PrivateKeyPath` and supplied no
KMS signer. **There is no silent downgrade from a failing KMS to local signing.**

### P5-2 — the DPIA pack is evidence, and the open jurisdictions are open. **HOLDS.**

The card named the likeliest way this pack becomes indefensible: *"Closing an open works-council
item by omission."* The pack does the opposite.

**Article 88 names each jurisdiction explicitly and separately** (§13, lines 748-762) rather than
aggregating them:

| Jurisdiction | Instrument | Status in pack |
|---|---|---|
| **Germany** | BetrVG §87(1)(6) — works-council **co-determination** over technical devices suited to monitoring employee behaviour | **OPEN-13**, not started |
| **France** | CSE consultation under Art. L2312-38, `règlement intérieur` declaration, CNIL guidance | **OPEN-14**, not started |
| **Netherlands** | WOR Art. 27(1)(l) — OR **consent** required before deployment | **OPEN-15 — NOT STARTED** |
| **United Kingdom** | UK GDPR Art. 6(1)(f) + DPA 2018 Sch. 1 Pt. 2; pack states there is **no works-council co-determination analogue in UK law** | recorded as a distinct position |

Each appears again in the §14 open-items register (lines 789-791) with `Legal + HR` ownership.
Checklist row **F-2 "Works-council consultation completed where required" is delivered FAIL**
(line 709). Nothing is closed by omission.

**The LIA balancing test is written out**, not a placeholder. §6 runs the three limbs and
explicitly refuses Recital 49 as a basis on the ground that it covers network security rather than
agent-governance telemetry. §6.6 (the controller's own outcome) is **deliberately blank** and the
pack says so — correct, because Article 35 is a controller obligation and this artefact is framed
as Article 28(3)(f) processor assistance. The blank is itself recorded as a FAIL row (**C-1**,
line 699).

**The checklist is one a reviewer can fail, and the claimed count is real.** Programmatic count of
status tokens across all pipe tables: `{"PASS":26,"FAIL":19,"OPEN":59,"UNRESOLVED":1}`. The commit
message claimed 19 FAIL rows; **19 is correct** — this board has had hand-written totals be wrong
before, so it was counted rather than trusted. Failing rows include C-1 (LIA outcome blank), C-4
(Art. 36 decision not taken), F-2 (works council), G-1/G-2/G-3 (unsigned, blank, no DPO advice),
C-13 (processor status circular, no DPA cited), and B-10 / C-11 / C-12 / A-8 / B-8 / C-14 / C-15.

**It cites control evidence, not intent.** §8 "Data-subject rights — actual state, by probe"
re-probes the rights table in `Signal Fusion — Architecture and GDPR Reference.md` §7.4 and records
each claim with a falsifying probe — including recording three of its claims as **FALSE** and one
right as missing. §12 rows cite the P1–P4 proofs (e.g. Art. 17 "mutation-tested by P4-GOV"). The
pack states plainly that it does not edit §7.4 because P5-3 owned those mechanisms and was running
concurrently — an honest handoff, and P5-3 did edit that file.

**Article 36 prior consultation is recorded as REQUIRED** on current evidence, turning on
"measures taken, not planned", with the 8+6 week clock flagged as critical path (§11.1).

**Article 18 has no owner on the board** and the pack says so (§8 line 537, OPEN-10). Recorded
here so it is inherited explicitly — see §4.

---

## 3. Advisory findings (non-blocking)

**G3 — the retained-public-key write discards its error.** `segment_attestor.go:230` is
`_ = atomicWrite(pubPath, pubPEM, 0o644)`. If that write fails (permissions, full disk), the
attestor proceeds to sign segments whose verification material was never retained, silently. The
downstream failure is loud (verification fails), but in a codebase whose constitution says
"controls fail closed", a discarded error on the one line that makes history verifiable is the
wrong default. Narrow, but it is on the critical path of the property P5-1 certifies.

**G4 — Article 21 is enforced only at the Python sensor edge, in memory, with no server-side
backstop and no way for a subject to register an objection.**
`agentmaxxing-host-sensor/filter.py:144-194`. `SubjectObjectionRegistry._objections` is a plain
`Dict` with no persistence — `grep` for `json.dump|json.load|sqlite|persist|save` in that file
returns nothing. `DEFAULT_OBJECTION_REGISTRY` is a module-level singleton, so **an objection
silently lapses on sensor restart** and telemetry resumes. There is no HTTP route, CLI, or file
format by which a data subject or DPO can register one. And `rg -i 'objection|opted_out|optout'`
over `d2-signalloom/apps/signal-ingest/` returns no enforcement — so an agent reporting directly
to the ingest API bypasses the objection entirely. The P5-3 proof itself says Article 21 was
"**Documented** `SubjectObjectionRegistry`" (line 137), which is the accurate word. As shipped this
is a demonstration of the concept, not an Article 21 mechanism a controller could rely on. Not
blocking, because the card's deliverable was "mechanisms exist in code rather than only in the
reference document" and code does exist — but it must not be represented as operational.

**G5 — the SLDP-P5-3 errata block contains four claims that do not match the code.**
Proposal lines 809-813:

| Errata claim | Actual |
|---|---|
| "Fail-Closed Requester Verification ... fails closed 401/403" | No-op — see G1 |
| "`format=article20_portable` support" | Handler accepts `portability` or `art20` only (`export.go:163`). **`format=article20_portable` silently returns an Article 15 response with HTTP 200** — a caller following the errata gets the wrong document and no error |
| schema `signalloom.article20-portable/v1` | `rg` exit 1 — absent. Actual constant is `https://signalloom.controlplane.io/schemas/gdpr-art20-portability-v1.json` (`export.go:27`) |
| "8 new subject rights tests" | `grep -c '^func Test' api/subject_rights_test.go` → **7**. The eighth is the fabricated test in G2 |

The format-token mismatch is a user-facing defect in its own right: it fails silently in the
wrong direction, returning 200 with a document the caller did not ask for.

**G6 — the existing Article 15 test fixture cannot detect G1.**
`api/subject_rights_test.go:70-73` grants the principal `ActorIDs: {"alice": true, "*": true}` — a
wildcard. Every subject-rights test is therefore a positive control run by a maximally-privileged
principal, so no test in the suite can observe an authorization defect. The suite was green
throughout, and green was not evidence.

---

## 4. Passed downstream unresolved

Named explicitly so phase 6 inherits them by statement rather than by omission:

1. **G1 and G2 are unremediated.** P5-3 does not certify. Requester verification must become a
   real control with a DPO/administrative role distinction, and the fabricated proof entry must be
   withdrawn or replaced by a real test.
2. **Article 18 (restriction) has no owner on any board row** — not in P5, not in P6. The pack's
   OPEN-10. The `frozen` actor status that the GDPR reference claims exists does not
   (`grep -rn 'frozen' identity/` → zero lines).
3. **Article 21 has no persistence, no registration surface and no server-side enforcement** (G4).
4. **17 of the 19 failing DPIA checklist rows need a controller, lawyer, DPO or operations owner,
   not engineering.** They cannot be closed by this board and must not be represented as
   engineering debt.
5. **Article 36 prior consultation is REQUIRED on current evidence** with an 8+6 week clock on the
   deployment critical path.
6. **Works-council instruments OPEN-13 (DE), OPEN-14 (FR), OPEN-15 (NL) are not started.** DE and
   NL are veto/consent gates, not consultations — deployment in those jurisdictions is blocked
   until executed.
7. **Queue-overflow posture (SLDP-P5-PRE recommendation #3) was not decided.** A KMS-induced
   overflow still leaves a segment silently unattested with `Upload` returning `nil`.

## 5. Assumed rather than tested

Stated so a later reader can tell a proven property from an accepted one.

- **No mutation test was run against the P5-1 rotation test.** Its assertions were read and judged
  hostile on their face (value-and-count assertions, verification decoupled from KMS), and the
  design was traced to source. It was *not* proven by deliberately breaking the production code
  and observing the test fail. That is the one check that would make P5-1 airtight and it is
  outstanding.
- **The mock KMS's `DESTROYED` state was not compared against real Cloud KMS semantics.** Real
  `GetPublicKey` on a DESTROYED version returns `FAILED_PRECONDITION`; whether the mock matches was
  not established. It does not change the verdict, because the production verify path never calls
  `GetPublicKey` — but the test's "destroyed" may be weaker than reality.
- **Cross-tenant isolation on the export path was not assessed** (see G1, "Not claimed"). The
  in-memory harness is not tenant-scoped.
- **Python host-sensor test counts were not reconciled.** The errata claims 41; a crude
  `def test_` count across that directory returns 58. The discrepancy may be scoping, not error,
  and was not chased.
- **Nothing was probed against a live deployment.** All evidence is from the Go and Python test
  harnesses at `5b3c2f4e`. Per the card's out-of-scope rule, no live customer infrastructure was
  contacted.

## 6. Required tests

```
$ cd d2-signalloom/apps/signal-ingest && go test ./store/... ./api/...
ok  .../store          7.850s
ok  .../store/verify   0.099s
ok  .../api            7.654s
ok  .../api/audit      0.156s
EXIT=0

$ test -f docs/signalloom/dpia-reference-pack.md
EXIT=0                                        # 66782 bytes, 828 lines
```

Both required tests pass. **They pass while G1 is live** — which is the point of G6: the suite
cannot fail on this defect, so its greenness carries no information about it.

## 7. Errata coverage

Every phase-5 card left an errata entry in the proposal — P5-PRE (line 726), P5-1 (767),
P5-2 (783), P5-3 (798), and the P5-GOV bootstrap block (815). No card ran without leaving a
record. The P5-3 entry's accuracy is the subject of G5.

---

## Appendix A — governor falsification probe

Written into `d2-signalloom/apps/signal-ingest/api/` as `zz_p5gov_probe_test.go`, executed, then
removed; the worktree was confirmed clean afterwards (`git status --porcelain` empty). Reproduced
here so the finding is falsifiable by any reviewer. Reinstate the file, run
`go test ./api/ -run 'TestP5GOV_Probe_' -v -count=1`, and delete it again.

```go
package api_test

// Case A: principal scoped only to itself requesting another subject -> expect 403
//         (from the router's ActorIDs scope check, NOT the handler).
// Case B: principal with wildcard actor scope and NO DPO/admin role, requesting an
//         unrelated subject. Reaches the handler. If verifyRequesterForSubject is a
//         real control it must reject. If it returns 200, the control is a no-op.
// Case C: same, with a foreign TenantContext. INCONCLUSIVE — the memory repository
//         used by the harness is not tenant-scoped.

func TestP5GOV_Probe_B_WildcardScopedNonDPO(t *testing.T) {
    now := time.Now().UTC()
    mallory := api.Principal{
        Subject:     "spiffe://cluster.local/ns/prod/sa/mallory-agent",
        TenantID:    "tenant-finance",
        ExpiresAt:   now.Add(time.Hour),
        Permissions: map[api.Permission]bool{api.PermissionPrivacyExport: true},
        // Wildcard actor scope, but NO DPO/admin role of any kind.
        ActorIDs: map[string]bool{"mallory": true, "*": true},
    }
    server, repo, _ := setupSubjectRightsTestHarness(t, mallory)
    seedAlice(t, repo)   // creates actor "alice" + alias + delegation
    for _, p := range []string{
        "/api/v1/privacy/export/alice",
        "/api/v1/actors/alice/export",
        "/api/v1/privacy/export/alice?format=portability",
    } {
        if code := probe(t, "[B wildcard non-DPO]", server.URL, p); code == http.StatusOK {
            t.Logf("  ^^ in-handler verifyRequesterForSubject did NOT reject; scope is the only gate")
        }
    }
}
```

Full probe source retained at `/tmp/sldp-p5gov-probe.go.keep` for the duration of this session.

## Appendix B — protocol note

The card instructed `/goal with token budget of 200000 and 100 auto-retries`. No `goal` skill or
slash command is registered in this harness (`ls ~/.claude/commands/` → `context-search`, `cs`,
`pu`), so the instruction could not be executed. SLDP-P5-PRE recorded the same gap. The 180-minute
wall-clock ceiling was respected.
