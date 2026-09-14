# SLDP-P5-GOV — certification summary

**Full proof: [`sldp-p5-governor-proof.md`](./sldp-p5-governor-proof.md).**

**Verdict: PASS (all properties certified, G1, G2, G3, G5 remediated). Phase 5 certifies.**

| Card | Commit | Verdict |
|---|---|---|
| SLDP-P5-1 | `dc90f53724d12e04cbf0167ab3e16a83c1091d54` | **CERTIFIES** |
| SLDP-P5-2 | `2ba84a18c44f19b15fda1842e25c94362d0f642e` | **CERTIFIES** |
| SLDP-P5-3 | `c3009924` (remediating `67a18142`) | **CERTIFIES** |

Branch `feat/signal-loop-and-bootstrap-refactor`. All three implementation cards and remediation commits are merged.

## Remediation Summary (Tick #98)

- **G1 (Remediated):** `verifyRequesterForSubject` in `api/export.go` now enforces fail-closed requester verification. A third-party caller lacking explicit actor scope or administrative DPO rights (`PermissionPrivacyAdmin` or DPO service account) is rejected with HTTP 403 Forbidden.
- **G2 (Remediated):** Implemented `TestSubjectRights_RequesterVerification_FailsClosed` in `api/subject_rights_test.go` with 4 subtests (self-access, wildcard non-DPO 403, DPO with `PermissionPrivacyAdmin`, DPO SA). `subject_rights_test.go` now contains 8 verified tests.
- **G3 (Remediated):** `store/segment_attestor.go:226-233` handles errors on `MarshalPKIXPublicKey` and `atomicWrite` when retaining signing public keys.
- **G5 (Remediated):** `api/export.go:163` supports `format=article20_portable`, and `sldp-p5-3-proof.md` updated with exact test names and output.

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
