# FAQ

Questions that have actually been asked, answered properly. If an answer here is only
a restatement of a feature name, it is a bad answer and should be replaced.

Deeper references: [`docs/signalloom/audit-trail.md`](signalloom/audit-trail.md),
[`docs/signalloom/display-currency.md`](signalloom/display-currency.md),
`audit_anchor/README.md`, and the comment blocks in the migrations and scripts named
below — those are the source of truth and they are more careful than this file.

---

## Audit trail

### Why does my audit row say the actor is an email address and not a name?

Because the email address is what the credential that authorised the action actually
carried, and a name is not.

`actor` is taken from the validated ID token — `Principal.actor` in
`d2-signalloom/apps/fe-signalloom/src/api_compat.py`. Dex issues an `email` claim when
the `email` scope is granted, so that is normally what lands in the column. If the claim
is absent, the token's `sub` is the only identity available and the row records that
instead.

There is no display-name lookup, deliberately. Resolving a friendly name means joining
against a directory at write time and putting the result of that join into an audit
column — so the row would then assert something the authorising credential never said,
and would silently change meaning if the directory changed later. The address is uglier
and it is defensible.

### Why does my audit row say `demo-actor`?

Because that row was written by a call site that has not been converted yet, and it
tells you nothing about who did anything.

This is a known, stated gap rather than a bug to file. The rows that name a real
operator today are the privileged-invocation rows and the writers converted alongside
them; a large number of other writers still pass the constant. `test_audit_event_types.py`
fails the build on any *new* `_audit_log()` call site passing a hardcoded actor, so the
population cannot grow, but the existing ones are being worked through separately.

Worth being blunt about: this limits what the anchoring below is worth. Integrity over a
record that carries no attribution is a well-witnessed log that says nothing about who
did what.

### Why can't I delete an audit row?

Migration `030_audit_events_append_only.sql` installs a trigger on `public.audit_events`
that refuses every `UPDATE`, `DELETE` and `TRUNCATE` with SQLSTATE `42501`. It is
statement-level, so `DELETE … WHERE false` is refused too — a caller that believes it can
mutate audit rows should find that out on the first statement rather than the first one
that happens to match something.

The threat it addresses is not a malicious DBA. It is the application rewriting its own
history: a compromised API process, an injection that reaches the writer, or a future
migration with a stray `UPDATE` in it. All three arrive over the application's own
database connection, so a control that refuses mutation on that connection stops all
three regardless of how the compromise happened.

**It is not a privilege boundary and should not be described as immutability.** The app
role owns the table and is a superuser here; anyone reaching the database as that role
can disable the trigger. A `REVOKE` was tried and measured — with `UPDATE` revoked and
the ACL showing it revoked, `has_table_privilege()` still returned true and a bare
`UPDATE` rewrote every row, because ownership and superuser both bypass grants. Triggers
are not privilege checks, which is exactly why they hold where the grant system does not.

If you need to correct the record, write a compensating event. That is what the trigger's
`HINT` tells you to do, and it is the right answer for an audit log in any case.

### How do I reset the demo now that the table is append-only?

```bash
make demo-signalloom-data-reset                 # everything
make demo-signalloom-data-reset SERVICE=audit   # audit_events only
```

That is the one sanctioned destructive path. It runs
`d2-signalloom/apps/fe-signalloom/src/db/data-reset.sql`, which lifts the guard
explicitly, truncates, and re-arms it as `ENABLE ALWAYS` — all inside a single
transaction, so a failure on any `TRUNCATE` rolls the disable back with it and the table
is never left unguarded.

Do not hand-roll your own version. Two things about it are non-obvious and both have
teeth. The guard must be lifted around the *whole* body rather than just the `audit`
branch, because `audit_events.agent_id` has a foreign key to `agent_registry` and
`SERVICE=agents` therefore reaches the table through `TRUNCATE … CASCADE`. And it must be
re-enabled with `ENABLE ALWAYS`, not a bare `ENABLE` — a bare `ENABLE` downgrades the
trigger to `ORIGIN`, which hands back the `session_replication_role = 'replica'` bypass
quietly, every time anyone resets the demo.

### `make audit-anchor-verify` says the chain is intact. What has it actually proved?

That no *anchored* row has been modified or deleted since its checkpoint, and if one had
been, which checkpoint window it happened in.

That is a real result and it is narrower than "the audit log is trustworthy". It does not
prove completeness — an event that was never written was never in the log and no amount of
hashing will reveal it. It does not cover rows written since the last checkpoint; `verify`
reports that count separately and never folds it into the verdict, so checkpoint cadence
is your exposure window. It does not localise below a checkpoint, so divergence resolves
to a window rather than a row until row-level chaining lands. And it prevents nothing at
all: it is a detector, so someone with `UPDATE` can still change a row, they just cannot
do it invisibly.

If the chain is empty it reports `proves_anything: false` and says so in words, because
"intact" over zero checkpoints is precisely the overclaim the component exists to avoid.

`make audit-anchor-tamper-demo` demonstrates the detection against the real table rather
than asserting it. Full statement of limits in `audit_anchor/README.md` — read that one
rather than this summary.

### Why does the stun audit row not say whether the agent was actually stunned?

Because the process writing the row cannot see whether it was.

The pod relabel and the OpenBao lease revocation belong to the SuperCred proxy, which
reports to nobody. The runner knows which privileged phase was invoked, by whom, and
when — so that is what the row says. A test asserts that it claims no outcome, because
adding one back is the obvious next mistake and it would be fabrication in a new place.

The row this replaced was richer and false: the browser POSTed it after a phase
succeeded, with the agent name, namespace and reason as string literals in the TSX, so it
recorded "compliance-failure: securityContext not set" whichever reason actually applied.
See the invariant in [`docs/signalloom/audit-trail.md`](signalloom/audit-trail.md).

### My new event type renders grey and I can't filter on it.

Three places need it and they fail differently, which is why this comes up:

* missing from `EVENT_COLORS` in `dashboard-signalloom/src/views/AuditTrail.tsx` → renders
  grey;
* missing from `EVENT_TYPES` in the same file → cannot be filtered at all;
* missing from the `audit_events` CHECK constraint → the write fails and
  `src/tests/test_audit_event_types.py` fails with it. Widen the constraint in a
  migration; the guard checks against the migration that runs *last*.

A related trap when you add one: every entry in `EVENT_TYPES` also renders as an
`<option>` in the filter `<select>`, so `screen.findByText('agent.stunned')` matches the
dropdown rather than the table cell and your assertion silently targets the wrong node.
Scope audit-table queries to the `tbody`.

### `make audit-anchor-*` fails on a key path in my worktree.

`.keys/` is gitignored and therefore per-checkout, while the cluster it signs for is
shared — so a worktree normally has no keys of its own and reaches the main checkout's.
The Makefile resolves that through `--git-common-dir`, which means `KEYS_DIR` is usually
an **absolute path outside your working tree** and every consumer has to honour it as
absolute.

Both mirror-image mistakes have shipped and are now covered by
`test/audit-anchor-keys-path.bats`: joining an absolute `KEYS_DIR` onto a base swallows
its leading slash, and passing a relative one through a `cd` resolves it against the
wrong directory. Use `keys_dir_abs` from `scripts/lib/keys.sh` in shell and
`$(abspath $(KEYS_DIR))` in make, before any recipe changes directory.

---

## Money and risk figures

### Why is a figure showing in dollars when the data is in pounds?

Because display currency is a per-user preference and it defaults to USD, while the demo
estate reports in GBP. Settings → Currency changes it, and the setting is saved against
your account rather than your team's — changing it does not move anyone else's numbers.

Whenever a figure has been converted, the conversion note beside it names the rate table's
`as_of` date. That note renders nothing when you are viewing figures in their source
currency, which is deliberate: a "converted at 1.0" line on every unconverted page trains
people to stop reading the line on the pages where it matters.

### Why is the FX table checked in rather than fetched live?

Because the FAIR engine pins its Monte Carlo seed so that a figure can be reproduced, and
a live rate lookup would undo that in one line. The same command with the same inputs and
the same seed would return a different number tomorrow, every historical report would
become irreproducible, and a tool whose pitch is that it runs offline with no cluster, no
network and no API key would acquire a network dependency on the critical path of a board
number.

So the rates are data in the repository: `risk/fx/rates.yaml` is authored,
`risk/fx/rates.json` is generated, and changing them is a reviewed pull request that
re-versions the money alongside the policy. `make fx` regenerates.

Stated in the file itself and worth repeating: these are **rounded reference rates
adequate for a demonstration estate**. They are not a dealt rate, not a mid-market close
from a named venue, and not suitable for settlement or a financial statement. An
institution running this for real replaces the file with its own treasury rates and its
own revaluation policy — which is precisely why the rates live in a file it can own
rather than in code it would have to fork.

### `make fx` failed with "reported success but did not vendor". What now?

The generator exited 0 and the artefact it was supposed to produce is still stale. `make
fx` runs each generator and then compares `risk/fx/testvectors.json` against the vendored
copy at
`d2-signalloom/apps/dashboard-signalloom/src/money/__fixtures__/fxTestVectors.json`; a
mismatch after generation means the generator lied about its own success.

**Fix the generator, not the artefact.** Copying the file by hand makes the message go
away and leaves the same defect in place for the next edit. This check deliberately
verifies and fails rather than repairing, because an earlier version repaired silently
and that is how the drift got in — a `console.log` saying "wrote X" over a write that
never happened is the exact failure shape this whole area has been chasing. It was
verified against a deliberately neutered generator.

If the dashboard side is absent on your branch the step is skipped rather than failing:
no generator means nothing downstream to regenerate, not a broken build.

### What does a non-zero sampler-guard count mean on a risk report?

That at least one drawn value in the simulation was **substituted rather than sampled**,
and the figures should not leave the building.

`fair.go` contains defensive substitutions that return a fabricated value rather than
hang on pathological input — `samplePERT` clamps a non-positive or NaN shape and returns
the triple's midpoint if both gamma variates degenerate, `gammaVariate` returns 0 for a
non-finite shape, `poisson` caps Knuth's loop. They are load-bearing and they came from
fixing a real infinite-rejection defect, so they stay. But each one silently substitutes
a number nobody computed, and "nothing would notice if it fired" is the same class of
defect as a currency conversion quietly assuming a rate of 1.0. Having made the latter
fail loudly, leaving the former silent would have been inconsistent.

So `riskctl` counts them and prints `⚠ SAMPLER GUARDS FIRED — DO NOT USE THESE FIGURES
EXTERNALLY` when the count is non-zero, and `Sampler guards: none fired — every drawn
value was sampled, not substituted` when it is zero. Guards are accumulated across *every*
simulation a report runs — the headline, the uncaged pre-pass, each per-control
hypothetical, each tornado leg — because a fabricated draw inside a delta is just as
fabricated as one in the headline.

In practice a non-zero count means an input triple is malformed in a way the loader did
not catch: an unordered triple (`mode < min`) is the demonstrated case. Fix the input.
The counting itself is proven not to perturb the model —
`TestCountingDoesNotChangeAnyDrawnValue` runs identically seeded counted and uncounted
generators side by side and requires all 20,000 draws per triple to match bit for bit.

---

## Running the demo

### Why is the instructor log empty for the first few seconds?

Usually because the phase has not printed anything yet — the log surface is shown from
the start rather than appearing when the first byte lands, so an empty panel is the
normal early state rather than a symptom.

The read is a long poll, not a plain poll: `/log?wait=` parks until there are bytes past
your offset, the run ends, or the deadline passes, so output reaches the panel within
milliseconds of the producer emitting rather than waiting out a poll interval. A wait
that expires is a normal empty read, not an error. Waiters are also woken when a run
reaches a terminal state, which matters more than it sounds — the last thing a step does
is exit, not print, so a waiter woken only by output would sit out its whole deadline at
the end of every phase.

If it is empty for the *whole* phase and you opted into `?logTransport=sse`, that is the
known SSE failure and it is why SSE is not the default. Any intermediary that buffers —
nginx (`proxy_buffering` is on by default and the `/demo-api/` block does not turn it
off), a Gateway compressor filter, ngrok, venue wifi running a transparent proxy —
accepts the connection, answers the headers, and then holds every byte until the response
completes. Nothing errors and `onerror` never fires. The stream carries a first-byte
watchdog for exactly this reason, rather than trusting an error that will not come. Drop
the query parameter and the waiting read cannot fail that way: it is an ordinary short
response, so a buffering proxy has nothing to hold.

### Why is there no UI toggle for the SSE log transport?

Because an instructor picking a transport mid-demo is making a decision they have no way
to evaluate, and the waiting read is the one that works everywhere. SSE is kept behind an
opt-in — `?logTransport=sse` for one demo with no residue, or
`localStorage['signalloom.logTransport'] = 'sse'` to make it sticky for a machine —
because the pattern is worth being able to demonstrate and judge. Neither route is
reachable by accident.

(Relatedly: the stream is read with `fetch()` rather than `EventSource`, because
`EventSource` cannot set a request header. Authenticating it would mean putting the
bearer token in the query string — into the nginx access log, every proxy log in
between, and the browser's own history, three places that outlive the session the token
belongs to.)

### What does "cannot verify" mean from the staleness guard, and why isn't it a pass?

It means the question was not answered: no `kubectl` on `PATH`, no reachable cluster, no
running pod, or the readback failed. Exit code 2.

It is not a pass because it is not evidence. `make check-deployed-staleness` exits 0 only
on a **positive proof** — every checked workload was reached, its build fingerprint was
read out of the running container's own filesystem, and it matched the working tree. Exit
1 is drift: something is provably running code other than yours. Exit 2 is the absence of
an answer, and the whole reason it is a distinct, loud, non-zero outcome is that a guard
reporting OK when it could not reach the cluster manufactures confidence — which is the
exact failure this script exists to remove, so it must not reintroduce it in its own
implementation.

That failure was real. On 2026-08-13 a streaming fix landed across 22 commits and was
verified by 315 backend tests, 1,657 dashboard tests and a browser harness. It was
reported as working. It was not: the pods answering the requests predated every commit —
`supercred-demo-runner` was 3h56m old with the old read still in `demo_runner.py`, and
the `dashboard-signalloom` bundle contained none of the fix. Every test was green and
every one of them tested the source tree. Nothing tested what was *running*.

Two things to know when you read its output. It compares a content fingerprint baked in at
build time and read back **out of the running container**, not a tag, git SHA or image
digest — tags were byte-identical across the rebuild that caused the incident, a git SHA
does not move on an uncommitted edit, and the pod-reported `imageID` is a local config
digest for one workload and a registry manifest digest for another, so it cannot be
compared uniformly. And a pass names what it checked rather than claiming "all clear",
because only instrumented workloads are covered: `fe-signalloom`, `fleet-manager`,
`cardvault`, `policy-engine` and the AFM backend are all built from this repo, carry no
build marker yet, and are **not** covered.

`make test-deployed-staleness` exercises the guard itself against a fake `kubectl`,
including that it cannot pass vacuously. No cluster required.

---

## Meta

### Where do I look first when something is wrong?

`make help` ends with a "Where to read more" block and a "Debugging first moves" block,
both maintained for this purpose. `make doctor` is the read-only cluster diagnostic. And
before believing any green test run about deployed behaviour, `make
check-deployed-staleness`.
