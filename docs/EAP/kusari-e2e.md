# Kusari pilot: testing the AWS signal path end to end

This page is the walkthrough for the Kusari AWS telemetry tests. The reader is a
Kusari or ControlPlane engineer. The reader wants to run the tests, read the
result, add a signal, add a rule, or replay a window.

It derives from the [SLAWS proposal](../Proposal%20—%20Signal%20Loom%20AWS%20Telemetry%20Ingest%20%26%20Multilayer%20Policy%20Engine%20Beta%20%282026-Q3%29.md)
§2.3 (the label contract), §3 and §4 (the two policy stages), and D3/D6/D7.
Sibling pages: [enforcement](enforcement.md), [faq-and-limits](faq-and-limits.md).

## What the pipeline under test is

AWS writes CloudTrail objects and VPC Flow Log objects into a bucket in the
Kusari account. The `awslogs` collector projects each record onto an observation
under the §2.3 label contract, and the observation travels this chain:

```
S3 object -> awslogs.Projector -> BindTenant -> DedupeSink -> policy.Sink -> StoreSink -> store
                                                                  |
                                                      stage 1 (CEL rules) -> findings
                                                      stage 2 (windows)   -> decisions
                                                                  |
                                                      DedupeSink -> StoreSink
```

Stage 1 is a CEL predicate per rule. Stage 2 is a keyed sliding counter declared
in the bundle, never in CEL. Both bundles the pilot ships are in `shadow` mode:
findings and decisions are stored, nothing is alerted and nothing in the AWS
account is touched.

The bundles are files, Flux-reconciled into a ConfigMap and loaded at boot:

| File | Bundle | Covers |
| :--- | :--- | :--- |
| `policy/bundles/kusari/iam-change.yaml` | `kusari-iam-change` | the narrow IAM privilege path |
| `policy/bundles/kusari/cloud-signals.yaml` | `kusari-cloud-signals` | EKS, console sign-in, STS, S3, GuardDuty, VPC Flow, and IAM more broadly |

They overlap on the IAM path deliberately. A finding's id hashes the bundle
version. So one `AttachUserPolicy` produces one finding per bundle, with
distinct ids and distinct rule ids. This is what lets the narrow bundle be
promoted to `warn` on its own schedule while the broad one stays in `shadow`.

## Running it

Offline. No cluster, no network, no AWS credentials, no clock.

```bash
make test-kusari-e2e
```

That runs `d2-signalloom/apps/signal-ingest/e2e` twice, once over the in-memory
store and once with `-tags frostdb` over the Parquet store the pod actually
runs. Use `-v` output: the suite prints a per-rule and per-window table, and a
bare pass tells you nothing about which signals were exercised.

The three narrower suites, if you want only one of them:

```bash
# the fixture projection against the §2.3 label contract
cd d2-signalloom/apps/signal-ingest && go test -run TestKusariFixtures -v ./collectors/awslogs/

# the synthetic stream generator on its own
cd d2-signalloom/apps/signal-ingest && go test -v ./collectors/awslogs/synth/

# the whole signal-ingest module, which includes all of the above
make test-signal-ingest
```

Re-render the ConfigMap after any bundle edit. A Go test fails if you forget,
so this is not optional:

```bash
make policy-bundles-render
```

### The live tier

```bash
KUSARI_LIVE=1 KUBECONFIG=~/.kube/config bats test/kusari-e2e-live.bats
```

Without `KUSARI_LIVE=1` and a real `KUBECONFIG` all seven tests skip, naming
both conditions. The live tier only observes. It never writes an observation
and never edits a cluster object. Its last test proves that by POSTing with
the read key and requiring `403`.

It answers what the offline suite structurally cannot. The bundles Flux
reconciled are the files in this tree, diffed per ConfigMap key. The running
pod loaded both at boot. Tenant `kusari` has findings, and every rule id
which fired is declared in this tree. `cloud-signals` is detecting rather
than merely loaded, and every policy row is still `shadow`. Each decision's
`count` equals the number of finding ids it cites, and every cited id
exists.

Override `WL_CONTEXT` (default `kind-osramp`), `INGEST_NS` (default
`fe-signalloom`), `KUSARI_LIVE_PORT` (default `28094`) and `KUSARI_LIVE_LIMIT`
(default `5000`) as needed.

### Seeding a live cluster and reviewing a decision

A cluster that is not yet pulling from a real queue has nothing for the review page to show. `make kusari-synth-seed` posts a recent synthetic stream (`cmd/kusari-synth`, deterministic for a seed) with the stun-sentinel key, which writes for tenant kusari. The default is thirty minutes of events at four a minute, which on the shipped bundles yields findings and a handful of windowed decisions inside the 90 m review window.

```bash
export KUBECONFIG=/path/to/kubeconfig
make kusari-synth-seed                    # SEED=7 MINUTES=30 RATE=4 by default
make kusari-synth-seed SEED=11            # a different corpus, same shape
```

`test/acceptance/signals-review.spec.ts` then proves the human loop end to end on that cluster: a superadmin logs in, opens `/signals`, records a verdict with a note on the first unreviewed decision, and the verdict is still there after a reload. The dashboard keeps no review state of its own, so a verdict that survives a reload was stored by signal-ingest through the gateway proxy. The spec skips, rather than fails, when the window holds no unreviewed decision.

```bash
scripts/acceptance-test.sh signals-review.spec.ts
```

## Reading the result

`make test-kusari-e2e -v` prints:

```
Kusari AWS signal e2e — stage 1
  bundle               rule                              want  got  status
  -------------------- --------------------------------- ----- ---- ------
  cloud-signals        console-login-outside-allowlist       1    1  ok
  cloud-signals        cross-account-assume-role             2    2  ok
  cloud-signals        eks-access-entry-created              2    2  ok
  cloud-signals        eks-cluster-config-changed            1    1  ok
  cloud-signals        guardduty-detection-tampered          3    3  ok
  cloud-signals        iam-credential-or-policy-change       3    3  ok
  cloud-signals        s3-bucket-exposure-changed            2    2  ok
  cloud-signals        vpc-egress-rejected                  23   23  ok
  iam-change           access-key-created                    1    1  ok
  iam-change           iam-priv-change                       1    1  ok
  iam-change           vpc-reject                           23   23  ok

Kusari AWS signal e2e — stage 2
  bundle               window                            want  got  status
  -------------------- --------------------------------- ----- ---- ------
  cloud-signals        cross-account-assume-role-burst-30m     1    1  ok
  cloud-signals        iam-change-burst-10m                  1    1  ok
  cloud-signals        vpc-reject-burst-5m                   1    1  ok
  iam-change           iam-change-burst                      0    0  ok

  stored: 47 observations, 62 findings, 3 decisions
```

The `want` column is the table in `d2-signalloom/apps/signal-ingest/e2e/expectations.go`.
Counts are asserted **exactly**, not as a lower bound. An over-triggering
rule is how a detection control becomes noise nobody reads, and a lower
bound cannot see it. Nothing may fire that the table does not name.

`iam-change / iam-change-burst` expecting `0` is not an omission. The Kusari
corpus reaches that rule once, and its threshold is three. So zero is the
correct answer. Stating it explicitly is the only way to catch a window that
would fire on a single finding.

## What each test claims

Offline, in `d2-signalloom/apps/signal-ingest/e2e`:

| Test | Claim |
| :--- | :--- |
| `TestKusariE2E_FixtureCorpusMatchesTheExpectationTable` | every rule and window matches the table exactly, both bundles are `shadow`, zero evaluator faults |
| `TestKusariE2E_EveryRuleHasANegative` | every rule names a negative fixture, and the object carrying it holds records the rule left alone |
| `TestKusariE2E_ReplayReproducesLive` | replay over the stored observations reproduces the live run byte for byte on the canonical projection |
| `TestKusariE2E_ReplayWithNoBundlesIsTheMutationGate` | replaying with an empty bundle directory produces nothing, so the equality above is not vacuous |
| `TestKusariE2E_SecondPassIsANoOp` | a second pass changes no row **and** is never seen by stage 1 or stage 2 |
| `TestKusariE2E_RestartDoesNotReAdmitTheCorpus` | a new accepted-ID set, warmed from the store, refuses what is already durable |
| `TestKusariE2E_MutationGates` | an empty bundle dir detects nothing but still ingests everything; removing the burst records removes the decisions |
| `TestKusariSynth_BaselineProducesNoFindings` | 3,000 benign generated records produce zero findings — the false-positive gate |
| `TestKusariSynth_EachBurstCrossesItsWindow` | each injected burst crosses exactly its own window and no other |
| `TestKusariSynth_ReplayReproducesLiveOverTheCombinedCorpus` | replay equals live over 3,072 records, fixtures and synthetic stream interleaved |
| `TestKusariSynth_SecondPassOfTheCombinedCorpusIsANoOp` | the no-op holds at volume, with zero deduper evictions |
| `TestKusariSynth_SameSeedProducesTheSameDetections` | one seed, identical findings and decisions, through the projection and both stages |

Under `-tags frostdb`:

| Test | Claim |
| :--- | :--- |
| `TestKusariE2E_FrostDBMatchesTheExpectationTable` | the same table holds over Parquet, so every projected label key is inside the segment allow-list |
| `TestKusariE2E_FrostDBRestartDoesNotReAdmitTheCorpus` | the original idempotency defect, in its original store |
| `TestKusariE2E_FrostDBReplayReproducesLive` | asserts replay over FrostDB equals live, byte for byte |

In `collectors/awslogs`:

| Test | Claim |
| :--- | :--- |
| `TestKusariFixtures_EveryObjectProjectsSomething` | no fixture in the replay set projects to zero observations |
| `TestKusariFixtures_SatisfyTheLabelContract` | every observation carries the §2.3 keys for its source and nothing else |
| `TestKusariFixtures_NegativeContractHolds` | no policy document, access key, MFA field or raw body reaches a label or a description |
| `TestKusariFixtures_IDsAreDerivedAndUnique` | ids are derived and reproducible, so replay deduplicates |
| `TestKusariFixtures_VPCFlowIndexSkipsHeaderAndComments` | the flow record index counts data lines only |
| `TestKusariFixtures_EventBridgeEnvelopeProjectsToNothing` | **pins a known gap** — see below |

In `collectors/awslogs/synth`: `TestGenerate_SameSeedIsByteIdentical`,
`TestGenerate_DifferentSeedsDiffer`,
`TestGenerate_ProjectsThroughTheProductionProjector`,
`TestGenerate_CarriesNoWallClock`,
`TestGenerate_BurstManifestMatchesTheProfile`,
`TestGenerate_BaselineIsHarmlessByConstruction`,
`TestGenerate_RejectsBadArguments`.

## Replay over a durable segment

**Replay over a FrostDB segment reproduces live, byte for byte on the canonical
projection.** Asserted by `TestKusariE2E_FrostDBReplayReproducesLive`, with the
mechanism asserted separately by
`TestKusariE2E_FrostDBReplayMechanism_PseudonymisedActorAndAllowlists`.

This was a known defect until the SLAWS replay-parity change, and the shape is
worth keeping because it explains the design.

Segment schema v2 is the privacy contract. `FrostDBStore.Append` pseudonymises
the actor into `hmac_actor_hint` and writes no cleartext `actor_hint` column.
So every observation read back carried an **empty** `ActorHint`, and
`policy.Replay` handed every rule `obs.actor == ""`.

Every allowlist in both bundles is a negative test on the actor. An empty actor
satisfies it, so replay fired against exempted identities and lost true
positives. Measured over the Kusari corpus, live produced 62 findings and 3
decisions. Replay produced 64 and 2.

The resolution is that the pseudonym **is** the actor identity, everywhere in
policy, on both paths. Three parts.

1. A stored row's `hmac_actor_hint` is used verbatim. A live observation's
   cleartext hint goes through the store's own pseudonymiser. Both land on the
   same value.
2. Bundle vars holding actor identities are named under `actor_vars` and
   rewritten into that same space at load. `Conform` refuses a rule comparing
   `obs.actor` against an undeclared var.
3. `cross-account-assume-role` no longer dissects the actor ARN. It compares
   the projected `actor_account_id` label against `aws_account_id`.

Verify it:

```bash
make test-kusari-e2e   # the frostdb pass logs the canonical line count
```

`docs/signalloom/runbooks/slaws-policy-replay.md` is corrected to match. It now
carries a section on the actor being a pseudonym, and its troubleshooting table
routes an allowlisted identity firing everywhere to the `actor_vars` omission.

The in-memory path was never affected, and `TestKusariE2E_ReplayReproducesLive`
remains its positive claim.

## GuardDuty findings: a known gap

The `guardduty-detection-tampered` rule covers GuardDuty **management** calls:
`DeleteDetector`, `UpdateDetector`, `CreateFilter`, `ArchiveFindings` and the
rest. This is what GuardDuty actually writes to CloudTrail, and it is the
detection-evasion signal worth the `critical` severity.

A GuardDuty **finding** is a different thing. It is delivered over EventBridge
in a `{detail-type, detail{...}}` envelope with no `Records[]` array. That
envelope is valid JSON, so `ProjectCloudTrail` decodes it successfully. It
returns **zero observations with no error**: a silent zero that reads exactly
like a quiet account.

`collectors/awslogs/testdata/kusari/guardduty-eventbridge-envelope.json` holds
one, deliberately **outside** `KusariFixtureFiles()` so it never reaches a
rule. `TestKusariFixtures_EventBridgeEnvelopeProjectsToNothing` pins the
zero. Closing the gap needs an EventBridge-shaped projection path with its
own §2.3 label rows. The alternative is a forwarder that re-shapes findings
onto the CloudTrail envelope before they reach the bucket.

## Three fields the rules cannot read

The projection is an allowlist of named scalars, and extending it is **not** a
projection-only change. `store/label_allowlist.go` is a closed key set, and
`FrostDBStore.Append` refuses an entire batch containing a key outside it. So
each of these is a coordinated change across two packages. Each is named in
the rule that carries it rather than papered over.

| Field | Where it lives | What the rule does instead |
| :--- | :--- | :--- |
| `additionalEventData.MFAUsed` | not projected | `console-login-outside-allowlist` discriminates on the **principal**. Root is never on the allowlist, so a root sign-in — the case the rule exists for — fires regardless. |
| `requestParameters.policy` | not projected, and forbidden by the §2.3 negative contract | `s3-bucket-exposure-changed` fires on the exposure-changing API **surface**, not on a verdict of public-ness. A deliberate over-trigger; `shadow` is where that is affordable, and the alternative is a policy-document parser on the ingest hot path fed attacker-influenced JSON. |
| `userIdentity.accountId` | not projected | `cross-account-assume-role` recovers it from the actor ARN with the CEL standard `startsWith`, so it needs no change to the evaluator env and correctly does **not** fire on the same-account role chains that are every CI job. |

The MFA field is kept in the fixture bytes so the console rule can be tightened
the day an `mfa_used` label exists.

## Adding a signal

A signal is a fixture object plus a row in the expectation table.

1. **Write the fixture.** Put it under
   `collectors/awslogs/testdata/kusari/`. CloudTrail objects are a
   `{"Records":[...]}` envelope. VPC Flow objects are version 2
   default-format text with the header line. Include **both** the records
   that should fire and the records that should not. A `_fixture` key at the
   top of the JSON documents which is which, and the projector ignores it.
2. **Register it.** Add a constant and a `KusariFixtureFiles()` entry in
   `collectors/awslogs/fixtures_kusari.go`. Do **not** add it to
   `FixtureFiles()`: that is the default replay set whose totals the projection
   card's contract tests assert.
3. **Check the contract.**
   `go test -run TestKusariFixtures -v ./collectors/awslogs/` — this is where a
   missing label or a leaked secret shows up.
4. **Keep the baseline honest.** If the new signal is a mutating API, add its
   event name to the banned list in `collectors/awslogs/synth/synth_test.go`.
   This keeps the false-positive gate meaningful. Make sure `benignEvents`
   in `synth.go` does not draw it.

Adding records to an existing fixture shifts the counts in the table. That is
expected: update the table, and read the diff.

## Adding a rule

1. **Write it** in `policy/bundles/kusari/cloud-signals.yaml`. Guard every
   label read with `has(...)`: a bare `obs.labels.k` on an absent key is an
   evaluation fault that degrades the whole bundle for that observation. Give
   it its own `id` and `severity`. One event should produce one finding per
   concern, which is why the EKS rules are split by what they grant.
2. **Give it both fixtures.** A positive that fires it and a negative that does
   not. `TestKusariE2E_EveryRuleHasANegative` fails a rule with no negative,
   because a rule that fires on everything passes a positive-only suite.
3. **Add the table row** in `e2e/expectations.go`, with the exact finding count
   and a one-line description of each fixture. Update `wantKusariFindings` and
   `wantKusariDecisions`. The suite cross-checks the tables against the totals.
4. **Add a window** if a burst matters. `key` may use `tenant_id`, `actor`,
   `rule_id`, or `labels.<key>`. See the caveat on `vpc-reject-burst-5m` in the
   bundle for what a label-keyed dimension costs at warm-up.
5. **Re-render and run.**

```bash
make policy-bundles-render
make test-kusari-e2e
cd d2-signalloom/apps/policy-engine && go test -run TestRenderedBundlesConfigMapIsCurrent .
```

A rule that does not compile, references an undeclared `vars` key, or yields a
non-boolean is rejected at **load**, not at evaluation. `obscel.Conform` is the
gate, and `LoadBundles` is fail-closed on a malformed bundle.

## Replaying a window

Replay re-evaluates stored observations through the same stage 1 and stage 2
code the live sink runs, with the clock replaced by observation timestamps. It
writes a canonical projection and never writes back to the store.

```bash
cd d2-signalloom/apps/signal-ingest && go run . replay \
  --bundles /etc/policy-engine/bundles \
  --from 2026-10-03T00:00:00Z \
  --to   2026-10-04T00:00:00Z \
  --tenant kusari \
  --out /tmp/kusari-replay.txt
```

`--from` and `--to` are RFC3339 and both required. `--out` is required. Point
`--bundles` at a working tree to ask what a **candidate** bundle would have
matched, which is the question replay is best at.

The full runbook is
[`docs/signalloom/runbooks/slaws-policy-replay.md`](../signalloom/runbooks/slaws-policy-replay.md).
Read the defect section above before trusting a replay over a durable segment.

An empty output file with exit 0 means one of three things. The bundle count
is zero, or there are no observations in the range, or the `--tenant` value
does not match the `tenant_id` label. Those are listed by order of
likelihood.

## Related

- Label contract: `d2-signalloom/apps/signal-ingest/collectors/awslogs/contract_doc.go`
- Pipeline shape and what it may not do: `d2-signalloom/apps/signal-ingest/policy/doc.go`
- Vocabulary and determinism contract: `d2-signalloom/pkg/obscel/doc.go`
- Suite overview: `d2-signalloom/apps/signal-ingest/e2e/doc.go`
- Expectation table: `d2-signalloom/apps/signal-ingest/e2e/expectations.go`
