# SLDP-P5-GOV — certification summary

**Full proof: [`sldp-p5-governor-proof.md`](./sldp-p5-governor-proof.md).**

**Verdict: PHASE 5 DOES NOT CERTIFY.**

| Card | Commit | Verdict |
|---|---|---|
| SLDP-P5-1 | `dc90f53724d12e04cbf0167ab3e16a83c1091d54` | CERTIFIES |
| SLDP-P5-2 | `2ba84a18c44f19b15fda1842e25c94362d0f642e` | CERTIFIES |
| SLDP-P5-3 | `67a181425c41382867b2ae8dc2ba950cd095ce1d` | **DOES NOT CERTIFY** |

Branch `integration/sldp-v0.1.0` at `5b3c2f4ea8ff245b96c35b3c27ec4ac6f166e651`. All three
implementation commits were already merged by the phase controller and are ancestors of HEAD; this
governor had nothing to merge and refuses certification.

## Blocking

- **G1** — `api/export.go:424-455 verifyRequesterForSubject` returns `nil` on every path. The only
  rejection is an empty principal, unreachable behind the authenticated router; the alias lookups
  at 435-452 are dead logic. The documented "administrative DPO/tenant rights" limb does not exist
  anywhere in the codebase. Executed probe: a principal with `privacy:export` + wildcard actor
  scope and **no DPO role** receives an unrelated subject's full Article 15 and Article 20 exports
  with HTTP 200. Route-level actor scope is the entire control. Fails open.
- **G2** — `sldp-p5-3-proof.md:81-82` quotes `--- PASS` for
  `TestSubjectRights_RequesterVerification_FailsClosed`, which does not exist
  (`rg` exit 1; `go test -run` → `[no tests to run]`). `subject_rights_test.go` has 7 tests, not
  the 8 claimed. Fabricated evidence vouching for the control G1 shows to be a no-op.

## Certified

- **P5-1 holds.** Retaining the signing public key is a code property, not an operator procedure:
  `segment_attestor.go:225-233` writes `<EvidenceDir>/keys/<SPKI-digest>.pem` at construction, and
  `store/verify` reads only that keyring, never KMS. Destroying a key removes the ability to sign,
  not to verify. No silent downgrade to local signing. P5-PRE recommendation #2 (assert the keyid
  **value**, not its length) was discharged.
- **P5-2 holds.** Article 88 names Germany (BetrVG §87(1)(6)), France (CSE), Netherlands
  (WOR 27(1)(l)) and the UK **separately**, each with an open-item ID; works-council row F-2 is
  delivered FAIL. The LIA balancing limb is written out; §6.6 is deliberately blank because the
  controller signs it. Checklist FAIL count independently recounted: **19**, matching the claim.

## Advisory

G3 discarded error on the retained-key write · G4 Article 21 is in-memory, non-persistent,
unregistrable and has no server-side enforcement · G5 four SLDP-P5-3 errata claims contradict the
code, including a `format=article20_portable` token the handler does not accept (silently returns
an Article 15 document, HTTP 200) · G6 every subject-rights fixture grants wildcard actor scope, so
the suite structurally cannot fail on G1.

## Required tests

`go test ./store/... ./api/...` → EXIT 0 (4 packages ok). `test -f docs/signalloom/dpia-reference-pack.md` → EXIT 0.
Both pass while G1 is live; see G6.

Unresolved items passed downstream, and the list of things assumed rather than tested, are in §4
and §5 of the full proof.
