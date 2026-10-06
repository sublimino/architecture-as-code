# Runbook — reviewing a policy decision and recording a verdict

**Status:** current. Written 2026-10-05 for the SLAWS review API. Every route, permission name and
status code below is pinned by a test; the test is named beside each claim so the document can be
checked rather than believed.

## What this is for

The policy pipeline produces findings (stage 1, one rule matching one observation) and decisions
(stage 2, a window of findings crossing a threshold). Nothing in that chain knows whether it was
*right*. This API closes that loop: a human reads what the pipeline concluded and records an
objective value judgement against it — `true_positive`, `false_positive`, or `needs_info`.

The `false_positive` count is the number that pays for the feature. Without it, "the policy engine
is noisy" is an anecdote and tuning is guesswork.

## The evidence model, and why a review is an observation

A review is stored as a `model.Observation` with `Source = "policy_review"`, alongside the
decision it judges, in the same columnar store.

That is a deliberate decision and worth stating plainly, because a reviews table in Postgres is
the obvious alternative. A decision is *evidence*: append-only, signed into a Parquet segment with
everything else the pipeline saw, swept by the same retention controller, readable through the one
query path (`QueryRange`) that every consumer already trusts. A human's verdict on that decision is
a different *kind* of fact — not derivable from the data, an assertion by a named person at a named
moment — but it has exactly the same evidentiary job to do. Somebody will later ask *who called
this a false positive, and when, and on what basis*, and the answer has to be as durable, as
attributable and as tamper-evident as the decision it judges.

A separate table would have needed its own migration, its own tenancy enforcement, its own
retention, its own attestation and its own place in every export — four of which are the controls
an auditor actually asks about, re-implemented beside the ones that already pass.

So the review goes in the store, and the costs are stated rather than hidden:

| Property | Value | Note |
| :--- | :--- | :--- |
| `Source` | `policy_review` | `policy.SourceReview` |
| `ID` | `sha256(tenant\|decision_id\|reviewer\|verdict\|note)` | `policy.ReviewID`; this derivation **is** the idempotency rule |
| `Timestamp` | **server wall clock** | The only wall-clock timestamp in the pipeline — see below |
| `Layer` | the judged decision's layer | So the rates chart groups a review with what it judges |
| `Fidelity` | `strong` | Not `definitive`: that is reserved for cryptographic proof, and a person's judgement is not that. `strong` ("verified chain") is what an authenticated, attributable, first-party assertion is. |
| `Confidence` | `1.0` | The review's own, **not** inherited from the decision: a decision built on circumstantial evidence can be judged with certainty by someone who knows what the workload does |
| `ActorHint` | the reviewer | |
| `RawEvidenceRef` | the decision id | |
| `Labels` | `decision_id`, `verdict`, `reviewer`, `note`, `tenant_id` | Closed set. The judged decision's own labels are **not** copied, so a review cannot re-expose a projected cloud value under a third source (`TestReviewObservationLabelSetIsClosed`) |

### The one wall-clock timestamp

Every other observation's `Timestamp` comes from the data — a finding's is its source
observation's, a decision's is the moment its threshold was crossed in the data — and the replay
oracle depends on that. A review has no such moment to borrow: it happened when the person clicked,
and the only clock that knows is the server's.

**Consequence: a replay cannot re-derive a review and must not try to.** The determinism contract
does not hold here, and this is the only place it does not.

### Revision, not overwrite

The verdict and the note are inside the derived ID. So:

- Re-sending the **identical** judgement (double-clicked button, retried fetch) derives the same ID
  and is collapsed by the same deduper that collapses a replayed observation. One row.
- Changing the verdict or a character of the note derives a **different** ID, and is a second,
  separately attributable assertion. The first one stays on the record; the decisions feed shows
  the latest. (`TestPolicyReviewRevisionIsASecondRowAndTheFeedShowsTheLatest`)
- Two people reaching the same verdict are two reviews. Collapsing those would destroy the only
  interesting case — agreement.

## Permissions

Two new permissions, and deliberately neither of them `observations:read`.

| Permission | Grants |
| :--- | :--- |
| `policy:read` | the three read feeds (findings, decisions, rates) |
| `policy:review` | recording a verdict |

Reading what the policy concluded and asserting whether it was right are different privileges held
by different people. Folding the reads into `observations:read` would have handed every existing
evidence reader the detections feed with no grant; folding the write into either read would have
made every reader a reviewer.

**`sldc-evidence-reader` holds `observations:read` only and therefore cannot review** — nor read
the policy feeds. Pinned by `api.TestEvidenceReaderKeyCannotReadOrReviewPolicy`, which also asserts
no review landed despite the refusal. `api.TestPolicyReadDoesNotGrantReview` pins the other half.

### Deployment action still required

No shipped static key holds either permission yet. To let the dashboard reach these routes, add to
`fe-signalloom-gateway` in `d2-signalloom/apps/signal-ingest/deploy/jwt-auth-config.yaml` **and**
to its row in `shippedKeyGrants` (`api/static_bearer_deploy_test.go`), which pins the grant
row-for-row:

```yaml
"permissions": ["tenant:act-for", "tenant:cross-read", …, "policy:read", "policy:review"]
```

Both files are outside this change's ownership; `api.KnownPermissions` already lists the two
permissions, so a grant will validate as soon as it is configured.

## Routes — signal-ingest

All under the existing authentication chain (`ActingTenantGate` → `ProtectedRouter`).

### `GET /api/v1/policy/findings` — `policy:read`

Query: `window=5m|10m|30m|90m` **or** `since=<RFC3339>` (mutually exclusive, 400 if both),
`tenant=<id>`, `limit=<n>`. Default window 30m.

Returns, newest first:

```json
[{"id":"…","timestamp":"…","tenant_id":"…","actor":"…","layer":"…",
  "source_observation_id":"…","rule_id":"…","bundle_id":"…","bundle_version":"…",
  "severity":"…","mode":"…","labels":{}}]
```

Built from stored observations with `source == policy_finding`, deduplicated with
`store.DedupeByID` **before** the limit — so a page is `limit` distinct findings, not `limit` rows
of which some are copies. An empty window serialises as `[]`, never `null`.

### `GET /api/v1/policy/decisions` — `policy:read`

Same query parameters. Returns, newest first:

```json
[{"id":"…","timestamp":"…","tenant_id":"…","actor":"…","window_id":"…","rule_id":"…",
  "bundle_id":"…","bundle_version":"…","severity":"…","mode":"…","count":2,
  "finding_ids":["…"],
  "review": null}]
```

`review` is `null`, or the **latest** `policy_review` for that decision:
`{id, verdict, note, reviewer, reviewed_at}`.

Reviews are collected over the **whole store**, not the requested window. A review is written when
the human clicks, which can be long after the decision it judges; scoping reviews to the window
would make a reviewer's own verdict vanish from a 5-minute view and prompt them to record it again.

A malformed `count` label yields `0` rather than dropping the row — the decision is real and still
needs reviewing (`TestPolicyDecisionsFindingIDsIsAnArrayNotNull`).

### `POST /api/v1/policy/decisions/{id}/review` — `policy:review`

Body (closed-world decoded; an unknown field is a 400):

```json
{"verdict": "true_positive|false_positive|needs_info", "note": "…"}
```

`201` with `{id, decision_id, verdict, note, reviewer, reviewed_at}`.

| Status | When |
| :--- | :--- |
| `400` | unknown or missing verdict; unknown field; note over 500 characters |
| `403` | principal lacks `policy:review` |
| `404` | unknown id, **or** an id that names a finding / raw observation / review, **or** another tenant's decision |
| `409` | this reviewer already recorded this exact verdict and note; the body names the existing review |

**The note is refused, not truncated.** Silently shortening it would alter the reviewer's stated
reason and then attribute the altered version to them (`TestPolicyReviewRejectsAnOverLongNote`).

**404, not 403, for another tenant's decision.** A 403 would make the route an existence oracle
over the whole estate: a reviewer would learn that `dec-b1` exists. 404 and "does not exist" are
deliberately indistinguishable (`TestPolicyReviewOfAnUnknownOrNonDecisionIDIs404`).

**The review is stamped with the decision's tenant, not the reviewing key's.** Otherwise a
cross-tenant reviewer's verdicts would all land under its own tenant and be invisible to the tenant
whose decision was judged (`TestPolicyReviewCannotCrossTenantsButACrossTenantReviewerCan`).

The write goes through `Handlers.Store`, which in production is the `policy.Store` wrapper — so a
review takes the same `Append`, the same deduper and the same segment attestation as every other
observation.

### `GET /api/v1/policy/rates` — `policy:read`

Query: `window`/`since`, `tenant`, `bucket=1m|5m` (default `1m`).

```json
[{"bucket_start":"…","layer":"…","source":"…","count":7}]
```

Over **all** observations in the window — raw, findings and decisions alike. The chart's job is to
show the pipeline working (signal in, findings out, decisions out), so filtering to policy sources
would remove the denominator that makes the other two series mean anything.

Ordered oldest bucket first, then layer, then source, so two calls over the same data draw the same
picture. Capped at 2000 rows, **keeping the newest** — a chart truncated at the right-hand edge
would hide whatever is happening now, which is the only part anyone is watching.

## Tenancy

The base is `observationReadScope`, the same function every observation read uses, so a reviewer
cannot see a finding it could not have seen as an observation.

- A non-cross-tenant principal sees only its own tenant.
- A principal with `tenant:cross-read` sees every tenant, and may pass `tenant=<id>` to narrow.
- A scoped principal may pass its **own** tenant (a no-op, accepted so a dashboard need not know
  whether its user is a superadmin before building a URL).
- A scoped principal naming **another** tenant gets `403 cross_tenant_read_required` — never an
  empty list, which would read as the false statement "that tenant has no decisions".

## Reviewer attribution

For a gateway holding `tenant:act-for`, the reviewer is the dashboard user named in
`X-SignalLoom-Acting-Subject`, prefixed with the key subject:

```
static-key/fe-signalloom-gateway/alice@example.com
```

Both halves are kept on purpose: the record says who asserted the verdict **and** which credential
carried them, and the two cannot be confused. The gateway's own key subject is shared by every user
behind it, so attributing a verdict to it alone would record "the dashboard" rather than a person.

For **every other principal the header grants nothing and is ignored** — exactly as in
`rateLimitKey` — so a key holding `policy:review` cannot forge somebody else's name onto a verdict
(`TestActingSubjectIsIgnoredWithoutActForTenant`).

## Routes — fe-signalloom gateway

| Dashboard route | Upstream |
| :--- | :--- |
| `GET /api/signals/policy/findings` | `GET /api/v1/policy/findings` |
| `GET /api/signals/policy/decisions` | `GET /api/v1/policy/decisions` |
| `GET /api/signals/policy/rates` | `GET /api/v1/policy/rates` |
| `POST /api/signals/policy/decisions/{decision_id}/review` | `POST /api/v1/policy/decisions/{id}/review` |

Tenant scoping is exactly what `/api/signals/observations` applies: `ingest_client.ingest_headers`
reads the tenant from the validated `Principal` and from nothing else, and sends the acting subject
so signal-ingest can name the reviewer. A missing gateway key is a `503`, never an anonymous
request.

The review body is **reassembled** from `verdict` and `note` rather than forwarded as received.
Upstream decodes closed-world and would refuse an extra field anyway, but a proxy that forwards
whatever arrived is how a `reviewer` or `reviewed_at` field eventually reaches a handler that trusts
it.

### Proving the loop on a live cluster

`test/acceptance/signals-review.spec.ts` records a verdict through the dashboard and reads it back after a reload. Seed decisions first with `make kusari-synth-seed`. The first live run of that spec on 2026-10-06 found two defects the offline suites could not see: the dashboard's four concurrent reads per poll OOM-killed signal-ingest at its 512Mi limit, and the rows acknowledged before the kill were gone afterwards. Both are fixed in the store (write-ahead log, bounded active block) and the decisions listing (window-bounded review lookup); the memory limit is now 1Gi.

### A superadmin reviewing another tenant's decision

The gateway's write acts for the reviewer's own tenant, and signal-ingest answers 404 for a decision that tenant cannot see. A superadmin reads every tenant, so the decision on `/signals` may belong to another one. On that 404 the gateway resolves the owner once, through the same read scope the page used, and repeats the write acting for that tenant. The common path, a reviewer's own tenant, stays one upstream call. `TestCrossTenantReview` in `src/tests/test_signal_policy.py` pins both.

### Who may review, through the dashboard

`signal_policy.require_policy_reviewer`, decided server-side from the validated token only. It
currently admits a `superadmin.is_superadmin` principal — the platform's existing server-side
identity check, the same one `auth_check` puts in front of every mutating fleet control. Every other
authenticated dashboard user is read-only with respect to review: they see all three feeds, and a
POST is `403 policy_review_forbidden`
(`tests/test_signal_policy.py::TestReviewGate::test_read_only_user_gets_403_on_review`, which also
asserts the request never reached signal-ingest).

**This is conservative and swappable.** The right long-term gate is `platform_users.role`
(`admin` / `editor` / `viewer`). It is not used here because it needs a database round trip this
proxy does not have, and a review gate that fails open when the pool is down is worse than one that
is narrow. `require_policy_reviewer` is the single function to change; nothing else in the module
knows how the decision was reached.

## Known deviation from the dashboard contract

**The effective maximum `limit` is 100, not 500.**

The handler enforces `limit <= 500` (`api.MaxPolicyLimit`). But the three read routes are
enumeration-budgeted, and `ProtectedRouter.applyEnumeration` refuses any limit above
`RouterOptions.MaxPageSize` — **100 by default, which is what production configures** — before the
handler runs. So `101..500` is a `400` from the router, and when no `limit` is given the router
injects `DefaultPageSize` (50).

Keeping the budget was the choice. It exists to stop an authenticated principal inventorying the
estate through a list route, and a feed of every detection is exactly the list route it was built
for; dropping enumeration to reach the number in the contract would have traded a real control for
a parameter value. Raising `MaxPageSize` makes the contract value reachable by configuration rather
than by a code change. Pinned both ways by
`api.TestPolicyLimitIsCappedByTheEnumerationBudgetBeforeTheHandler`.

## Label allow-list

Under `-tags frostdb` the segment allow-list is a **closed** set of label keys, and a disallowed key
refuses the **whole batch** at the `Append` chokepoint before any Arrow record is built. Four keys
were added for reviews: `decision_id`, `verdict`, `reviewer`, `note` (`tenant_id` was already
admitted).

Without them every review POST would return `500` under frostdb while every memory-store unit test
passed — the memory store has no allow-list, so only a frostdb-tagged test can see it. Hence
`store.TestFrostDBAdmitsAPolicyReviewRow` (appends and reads back) and
`store.TestReviewLabelKeysAreIndividuallyAllowed` (names which key is missing, since one absent key
refuses the batch and a whole-review test cannot say which).

**`note` is the one key here whose value is free text a person types.** `Append` checks the key and
never the value, so a note reaches a signed segment verbatim. Three things bound that and none of
them is the allow-list: `policy.MaxReviewNoteLen` caps it at 500 runes, only a principal holding
`policy:review` can write one, and it is attributed to the reviewer who typed it. Refusing the key
instead would have cost the only field that says *why* a decision was judged the way it was, which
is the whole evidentiary point of recording the judgement.

## Verification

```bash
cd d2-signalloom/apps/signal-ingest
go test -count=1 ./api/ ./policy/ ./store/
go test -count=1 -tags frostdb ./api/ ./policy/ ./store/

cd ../fe-signalloom/src
UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 \
  --with pytest --with pytest-asyncio --with pytest-xdist --with respx \
  --with-requirements requirements.txt python -m pytest tests/test_signal_policy.py -q
```
