# Display currency

> Living documentation. The engine-side model — denomination, rounding, where a
> conversion actually bites, territory scoping — is documented at
> [`risk/README.md`](../../risk/README.md) § *Denomination* and § *Territory*, and the
> rates file argues its own case in `risk/fx/rates.yaml`. This file covers the half those
> two do not: what a signed-in user sees, where the preference lives, and how the
> generated artefacts are kept honest.

## What it is

Every risk figure in the product is GBP at source and is shown in the user's chosen
currency. **The default is USD**, which means the common case is a converted figure —
worth knowing before you conclude a number is wrong.

The preference is per-user, not per-tenant. Changing it in Settings → Currency does not
move anyone else's numbers. It is stored server-side against the signed-in user, so it
follows them to another machine, and changing it writes an audit row.

That durability is why the control has its own card rather than sitting as a third field
under *Display*. Load Times next door is a browser-local preference remembered on one
browser only; putting the two under one heading would imply the same durability for both,
and the one that is merely local is the one people would assume travels.

## Where it lives

| Thing | Where |
|-------|-------|
| Storage | `user_preferences` (migration `020_user_preferences.sql`) |
| Audit event type | migration `021_user_currency_event_type.sql` |
| The control | `dashboard-signalloom/src/components/CurrencySetting.tsx` |
| Formatting and conversion | `dashboard-signalloom/src/money/` |
| Provenance line | `dashboard-signalloom/src/components/ConversionNote.tsx` |
| Authored rates | `risk/fx/rates.yaml` |
| Generated rates | `risk/fx/rates.json`, `risk/fx/testvectors.json` |

Migration 020 is worth reading if you are adding the *next* per-user setting: it is the
first one the product has ever had, so it sets the precedent rather than following one,
and it records why a `user_preferences` table beat a column on `platform_users` — chiefly
that a caller authenticated against a tenant may legitimately have no `platform_users` row
at all, so the `NOT NULL DEFAULT` argument for a column does not actually hold.

## The `as_of` date follows the figure

Wherever a converted figure appears, the rate table's `as_of` date appears with it. A
converted number with no stated rate and no stated date is a number nobody can defend when
a regulator asks how the figure on slide 12 was arrived at — and since the whole reason the
FX table is checked in rather than fetched is that the rate should be traceable, the date
has to actually reach the screen.

`ConversionNote` renders **nothing** when no conversion happened, i.e. when the user is
viewing figures in their source currency. That silence is deliberate: a "converted at 1.0"
line on every unconverted page teaches readers to skip the line on the pages where it
matters.

## Rates are a file, and what that costs

The rationale is argued in full at the top of `risk/fx/rates.yaml`; the short version is
that the FAIR engine pins its Monte Carlo seed so a figure can be reproduced, and a live
rate lookup would undo that in one line — same command, same inputs, same seed, different
answer tomorrow.

The limit is stated in the same file and should never be softened in a summary of it:
these are **rounded reference mid-market rates adequate for a demonstration estate**. They
are not a dealt rate, not a close from a named venue, and not suitable for settlement or a
financial statement. An institution running this for real replaces the file with its own
treasury rates and its own revaluation policy — which is why the rates live in a file it
can own rather than in code it would have to fork.

To update them: set `as_of` to the date the rates were *observed* rather than the date you
edited the file, name the `source` precisely enough for a reviewer to re-fetch, keep
`base: USD` with `USD: 1.0` (the loader rejects any other base, because a base rate of
anything else silently scales every cross rate), then re-run the report and diff. Movement
in a GBP-denominated figure means something is wrong, since GBP→GBP does not consult the
table at all.

## `make fx`, and why it fails instead of fixing

```bash
make fx    # regenerate risk/fx/*.json from rates.yaml, and every downstream generated copy
```

One command, because the dashboard cannot parse the authored YAML and therefore generates
a TypeScript copy from `risk/fx/rates.json`. Regenerating both here keeps "update the
rates" a single step; splitting it means the two artefacts drift between the edit and
whenever somebody remembers the second one.

After every generator has run, `make fx` compares `risk/fx/testvectors.json` against the
vendored copy at `dashboard-signalloom/src/money/__fixtures__/fxTestVectors.json` and
**fails** if they differ:

```
fx: FAILED — …/fxTestVectors.json is stale after generation.
fx:   …/generate-rates.ts reported success but did not vendor
fx:   risk/fx/testvectors.json. Do not hand-fix the artefact — fix the generator,
fx:   or the next edit silently drifts again.
```

It verifies and fails rather than repairing, and that distinction is the entire point. An
earlier version copied the file and printed a warning, which is how the drift arrived in
the first place — a `console.log` reporting "wrote X" over a write that never happened is
exactly the class of failure this area has spent a lot of time chasing. Verified against a
deliberately neutered generator.

On a branch where the dashboard side has not landed, the step is skipped rather than
failing: an absent generator means nothing downstream to regenerate, not a broken build.
The dashboard's own staleness test is the backstop if it is ever skipped when it should
not have been.

## Reading a report

Two lines on a `riskctl` report relate to this and are easy to skim past.

**`TERRITORY SCOPE: …`** names how many loss scenarios are global and how many are
jurisdiction-scoped, so that territory filtering is visible rather than merely applied.
An out-of-territory control is still evaluated for compliance — it can be unmet whether or
not its scenario can be incurred here. See `risk/README.md` § *Territory*.

**`Sampler guards: …`** is a correctness signal, not a currency one, but it prints
alongside. `none fired` is what you want. A non-zero count means at least one drawn value
was substituted rather than sampled and the figures must not be used externally — see
[`docs/FAQ.md`](../FAQ.md#what-does-a-non-zero-sampler-guard-count-mean-on-a-risk-report).
