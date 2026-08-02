# What Does A Breach Cost — talk distillation

Source: `~/Downloads/What Does A Breach Cost AJM Talk.mp4` (290.6 s, 1920×1080, 30 fps, 8714 frames).
Deck identifier from the slide footer: `POLICY_AS_VERSIONED_FLUX`, 20 slides.

This is not a conference talk in its current form. It is an **internal ControlPlane funding pitch**
— the closing slide is "FUND IT." with a `FUND THE BUILD` call to action. The conference talk is
one of the three things the funding *buys*.

## Artefacts in this directory

| Path | What it is |
| --- | --- |
| `audio/talk-16k.wav` | 16 kHz mono PCM extracted from the mp4 |
| `transcript/talk-16k.{txt,srt,vtt,tsv,json}` | Whisper `medium.en` transcript, 767 words |
| `frames/scene-*.jpg` | 23 scene-change frames — one per slide transition, full fidelity |
| `frames/grid1fps/t*.jpg` | 291 frames at 1 fps — complete temporal coverage of the 290.6 s runtime |
| `frames/contactsheets/sheet-0*.jpg` | 5 sheets, 6×10 tiles at 1 fps — every second reviewable in five images |
| `frames/scene-info.log` | ffmpeg `showinfo` output with scene-change timestamps |

Frame strategy note: the source is a static slide deck at 76 kbps video. Extracting all 8714 frames
would produce ~1.5 GB of near-identical JPEGs. The three-class extraction above gives **complete
coverage** (every second present in the 1 fps grid and the contact sheets) plus **full fidelity at
every transition** (scene frames), without the redundancy.

## The thesis, in the speaker's own words

> "What does a breach actually cost you? Not a red, amber, green dot on a dashboard — a number in
> pounds. Most governance ignores that. Compliant or not: a green tick that prices nothing and moves
> nothing. A binary lie."

> "Governance is not a checkbox. It is a proportionate, continuously retuned response to quantified
> risk — and it is all one thing: the policy. How your organisation actually operates, written down
> as code."

## The twenty slides

| # | Title | Kicker | The beat |
| --- | --- | --- | --- |
| 01 | WHAT DOES A BREACH COST? | THE ONLY QUESTION THAT MATTERS | Not RAG. A number, in pounds. Most governance is a binary lie. |
| 02 | IT'S ALL THE POLICY | THE IDEA | A proportionate, continuously re-tuned response to quantified risk — one artifact. |
| 03 | POLICY IS A VERSIONED DEPENDENCY | THE REFRAME | `policy-pack v2.1.0 · signed`. Pin, sign, adopt by PR. A lint pack engineers already know how to consume. |
| 04 | SAME CONTROL. TWO INSTITUTIONS. | THE MONEY SHOT 1/3 | `driftwood` (retail · PCI+GDPR) and `ludlow` (US health · HIPAA) run one identical rule: *encrypt at rest*. |
| 05 | AUDIT HERE. DENY THERE. | THE MONEY SHOT 2/3 | Retail → **AUDIT** (lower £). Health → **DENY** (far higher £). **The £ decides.** |
| 06 | RUN — BUT CAGED | NOT BINARY | TRUSTED → CONSTRAINED → CAGED → DENIED. "Least trusted = most expensive to run. A spectrum, not a cliff edge." |
| 07 | TOTAL COST OF RISK | THE ECONOMICS | `residual £ (risk you keep) + cost of controls (the cages) + risk transferred (insurance) = TCoR`. "Staying current is, provably, the cheaper path." |
| 08 | THE £ IS REAL — AND IT MOVES | PRICED, NOT GUESSED | Loss-exceedance curve. **ALE** (mean) · **VaR₉₅** (bad year) · **TVaR** (the tail). **£120K residual · warn-only → tighten to enforced → £18K residual · enforced.** |
| 09 | YOU MAY X — IF C | NO MORE EXEMPTIONS | ~~EXEMPTION~~ → CONDITIONAL POLICY. `allow if attestation ∧ data-class ≠ PII ∧ team ∈ {…} ∧ within-window`. Uniform · versioned · every branch carries its own priced residual £. |
| 10 | POSTURE IS IDENTITY | ZERO TRUST, MADE REAL | The policy version you satisfy becomes your identity. Workload, human, device — each carries it cryptographically. Verify, don't trust. |
| 11 | CAUGHT IN CI, NOT AT DEPLOY | FAILURES MOVE LEFT | Policy compatibility · ±1 version skew. Runs the target cluster's real admission action, offline. Audit→Deny flip caught before merge. |
| 12 | THE ESTATE WAR-GAMES ITSELF | THE LIVING LOOP | threats · CVEs · fines → WAR-GAMER stress-tests controls → drift? → signed PR → human + gate → estate re-tunes → £ moves. |
| 13 | THE A.I. OPENS A P.R. | PROPOSE, NEVER DISPOSE | `war-gamer[bot]` wants to merge "Retune encrypt-at-rest → Deny in ludlow". Awaiting human review. **Proposes — never merges.** |
| 14 | EVERY ACTOR SIGNS | VERIFY, DON'T TRUST | `gitsign (keyless) → Rekor`. `actor: war-gamer[bot] from: cve-feed@v2026.07 verdict: signed`. Which actor changed what, when, from which evidence — provable. |
| 15 | SIX REAL ORGS, BROUGHT TO LIFE | WHAT YOUR FUNDING BUILDS | `-nist` (OSCAL controls) + `-ico` (penalties→£) → `-platform` (FAIR · war-gamer · Flux · ledger · shift-left · OSCAL) → `-driftwood` (retail) · `-tuppence` (fintech) · `-ludlow` (health). All LIVE, real, on GitHub. |
| 16 | FLUX IS LOAD-BEARING | WHY THIS IS OURS | Not a logo — the spine. Six real jobs: distribution · provenance · prune-on-retire · drift-heal · ordering · events. |
| 17 | RISK ON THE BALANCE SHEET | THE CLOSE | Residual risk becomes economic capital — an underwriter would price the very same controls. A line your board can read, defend and act on. |
| 18 | WHAT YOU GET | THE PAYOFF | 01 flagship talk that tours · 02 demo estate for any prospect · 03 a narrative no competitor tells. |
| 19 | THE WINDOW IS OPEN | WHY NOW | "Every board is asking how to trust A.I. inside their business. We answer it — provably, on stage, in pounds. Whoever tells this story first, owns it." |
| 20 | FUND IT. | THE ASK | "Fund the full build — through to the flagship talk. I'll hand you the estate that proves governance can be proportionate, honest, and alive." |

## The mentality — seven operating rules

These are the load-bearing beliefs. Everything built downstream must obey them.

1. **A number, not a dot.** RAG status is a binary lie. The output of governance is a currency
   figure with a distribution behind it. *"Not a red, amber, green dot on a dashboard — a number in
   pounds."*

2. **Proportionality is computed, not chosen.** The same control produces opposite verdicts in two
   institutions *because the pounds differ*, not because someone had an opinion. *"Same control,
   opposite verdict, because the pounds say so."*

3. **Consequence is a spectrum, not a cliff.** Falling behind does not mean blocked — it means
   throttled, sandboxed, watched more closely, and **more expensive to run**. Deny is only the
   bottom rung. *"Least trusted, most expensive to run."* This makes staying current *provably* the
   cheaper path rather than a compliance obligation.

4. **Exemptions are abolished, not managed.** No carve-outs, no favours. `You may X if C`, applied
   uniformly to anyone meeting C, versioned like everything else, with each permissive branch
   carrying its own honest line of accepted risk. *"We kill the ugliest word in governance."*

5. **Posture is identity.** The policy version you satisfy *is* your cryptographic identity. A
   sensitive service refuses anyone who has fallen out of date. This is what makes zero trust
   operational rather than aspirational.

6. **Propose, never dispose.** The agent reads the feeds, war-games the controls, and when
   proportionality drifts it does exactly one thing: **opens a pull request**. A human reviews, the
   gate checks, and only then does it ship. *"A powerful machine, safe on your existing rails."*
   Every actor — human or machine — signs its work into a transparency log.

7. **The number belongs on the balance sheet.** Residual risk is economic capital. The controls an
   underwriter would price are the same controls the policy enforces. That is where a security talk
   closes if it is honest. *"Technological risk — finally, a line your board can read, defend and
   act on."*

## The maths named on stage

- **FAIR**: Risk = Loss Event Frequency × Loss Magnitude.
- **beta-PERT** over `(min, mode, max)` calibrated estimates → **seeded Monte Carlo** → an aggregate
  annual-loss distribution.
- **ALE** = mean of that distribution. **VaR₉₅** = 95th percentile ("the bad year").
  **TVaR** = mean of the tail beyond VaR₉₅ ("the tail your board actually fears").
- **Risk load**: never charge the mean — the carried £ is `TVaR + load`.
- **TCoR** = residual + cost of controls (including the run-cost of cages) + risk transferred
  (premiums).
- **What a control buys** = `ALE_warn − ALE_deny`, judged against a tolerance band. This is how
  Audit→Deny becomes a number instead of a timer.
- The four risk-financing moves — **avoid · reduce · transfer · retain** — mean *insurance is a
  control option* the model weighs, not an afterthought.

Deck's own worked example (slide 08): **£120K residual under warn-only → £18K residual under
enforced.** Source frame: `frames/grid1fps/t0102.jpg`.

## What this repo takes from it

`osramp-demo` adopts rules 1–7 as design principles and implements the maths above in
`tools/riskctl`, applied to a subject the upstream estate names but never prices: **the AI agent as
a posture carrier**. See `docs/policy-as-versioned-code/INTEGRATION.md`.
