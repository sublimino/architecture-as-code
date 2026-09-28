# EAPR-P1-GOV Impossibility Proof Rerun

Captured: 2026-09-24 08:25:40-05:00

## Forged proposal-only pass

The forged `EAPR-P4-GOV` marker was not accepted as execution proof:

```text
status=claimed
proceed=true
corroborated=false
corroboration=no task_runs row with exit_code 0 and outputLinesTotal > 0 for 15d5e; predecessor EAPR-P1-GOV is fail, not pass; predecessor EAPR-P2-GOV has no errata entry (absent); predecessor EAPR-P3-GOV has no errata entry (absent)
```

`done-advance --dry-run` did not advance the forged card, but it also did not
print the explicitly required SKIP line because the card is absent from the
current board listing. Therefore the live end-to-end proof is incomplete.

The isolated D11-1 positive control passes: a real exit-zero, non-empty run
remains `status=pass` and `corroborated=true`.

## Newest zero-output run

Mutation row D11-3 is red against the pre-fix executable and green against the
merged executable. Its green case proves that an implementation card is
skipped when its newest run has `exit_code=1` and `outputLinesTotal=0`, even
when an older qualifying run exists.

The current runtime database has no `task_runs` row for any of the thirteen
historical card IDs named by the P1-1 evidence. The requested retained-card
demonstration therefore cannot be made from the current clean state without
fabricating runtime state, which the governor is forbidden to do.

## Result

The logical predicates are mutation-tested, but both required live
demonstrations are not complete. This is a certification failure.
