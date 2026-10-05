# Documentation and test alignment gaps

Where a page describes behaviour that no test covers. `scripts/docs-tests-alignment.sh`
checks that every claim a living page makes about the test suite is true. It
cannot invent a test for a claim nothing covers, so each such step is recorded
here with a gap id, and the id is cited from the walkthrough map at
[`test/fixtures/walkthrough-map.tsv`](../../test/fixtures/walkthrough-map.tsv).

A gap is not a defect in a page. It is a named piece of described behaviour that
no gate defends, so it can rot without anything going red. Closing a gap means
writing the test, not deleting the sentence.

## GAP-ONB-1 — the invite flow has no browser acceptance spec

Date: 2026-10-05. Page: [`docs/EAP/onboarding.md`](../EAP/onboarding.md), step
`## 1. Get an identity`.

The step walks a reader through requesting an invite, opening
`/redeem-invite?token=<token>`, and selecting **Redeem invite**. It also states
three refusals by code: `403 invite_email_mismatch`, `409 tenant_mismatch`, and
`410` for an expired or spent invite.

The server side of that is covered. `d2-signalloom/apps/fe-signalloom/src/tests/test_invites.py`
drives `POST /api/v1/invites`, `POST /api/v1/invites/redeem`, and the refusals.

The browser side is not. No file in `test/acceptance/` loads `/redeem-invite` or
drives `RedeemInvite.tsx`, so the page, its token field, its submit control, and
the tenant it reports after a successful redeem are undefended. A rename of the
route or of the control would leave every suite green and the walkthrough wrong.

To close it: an acceptance spec that signs in as an identity with no tenant,
opens `/redeem-invite` with a seeded token, redeems, and asserts the reported
tenant. That needs a seeded invite row, which the suite has no helper for yet.

## GAP-ONB-2 — step 4 asserts an audit event the spec does not read

Date: 2026-10-05. Page: [`docs/EAP/onboarding.md`](../EAP/onboarding.md), step
`## 4. How your agents appear`.

The step's Check says that after a claim, `/audit` shows a claim event for the
agent. `test/acceptance/discovery-claim.spec.ts` asserts the governed transition
and the toast, and it never opens `/audit`. The audit half of the Check is
documentation only.

To close it: extend that spec to open `/audit` after the claim and assert a
claim event naming the agent.
