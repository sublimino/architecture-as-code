# The audit trail

> Living documentation. If this file and the code disagree, the code is right and this
> file is a bug.

This describes where audit rows come from, what the storage guarantees, what the
anchoring proves, and — most importantly — the rule that decides where the next audit
row should be written. The rule is first because it is the part that keeps being
rediscovered the expensive way.

## The invariant

**An audit event is a side effect of the action the API itself performs.**

It is never content the client supplies. It is never a record of an action performed
somewhere else. It is never written by a browser. A row records what its writer
observed, and nothing else.

Put operationally: if a front-end action needs to be audited, that action must go
through an API request, and the API that performs it writes the row. There is no
endpoint whose purpose is to accept an audit event, because an endpoint that accepts
an audit event is an endpoint that accepts a *claim* about an event.

### The corollary that decided several designs

**A field that crosses the wire is a field the next caller can author.**

This is the reason the rule is absolute rather than a matter of taste. A payload field
is not a value the server learned; it is a value the server was told. The two are
indistinguishable in the database and they are indistinguishable to whoever reads the
trail six months later during an incident. Once a field is accepted from a client,
every future caller — including a compromised one, and including a well-meaning
refactor — can put whatever it likes there, and the row will look exactly as
trustworthy as one the server derived.

So the test for a proposed audit field is not "is this useful?" but "did the process
writing this row *observe* it?". If the answer is no, the field does not go in the row.
Not as a nullable. Not as a hint. Not with a comment saying the client is trusted here.

### What this costs, stated honestly

Following the rule usually makes the trail **less rich and more true**. That trade is
the point, but it is a real trade and it should be visible when you make it.

The worked example is the demo runner. The browser used to POST an audit event after a
SuperCred phase succeeded, and that row said "agent X in namespace Y was stunned
because its securityContext was not set". Detailed, readable, and fiction: the agent
name, the namespace and the reason were string literals in `SuperCredInstructorPanel.tsx`,
so the row said exactly that regardless of which agent, which namespace, or which
reason actually applied. It was also contingent on a browser tab staying open and a
token staying valid — and Dex runs `storage: memory` here, so `make public` restarts it
and invalidates tokens as a matter of routine.

What replaced it (`_record_privileged_invocation()` in
`d2-signalloom/apps/fe-signalloom/src/demo_runner.py`) says "superadmin *person* ran
privileged phase 4 at *time*". That is less interesting and it is what the server knows.
It deliberately claims **no outcome**: the pod relabel and the OpenBao lease revocation
belong to the SuperCred proxy, which reports to nobody, so the runner cannot see whether
either happened. A test asserts the absence of an outcome claim, because reintroducing
it is the obvious next mistake.

### Two ordering rules that fall out of it

**Audit before the side effect, when the side effect is not a database write.** The
runner records the invocation *before* spawning the process. A row written on completion
is missing from precisely the cases worth investigating — pod killed mid-run, script
wedged, node lost. The security-relevant fact is that someone with superadmin invoked
this against the cluster, and that is true the moment the request is authorised. Ordering
is the guarantee: audit first, spawn second, so a spawn cannot happen without a record,
and a failed audit means no run.

**Audit inside the transaction, when the side effect *is* a database write.** Where there
is a row to bind to, bind to it. Where there is not — a subprocess and a mutated cluster
are not a row — say so in the code rather than implying a transactional guarantee that
does not exist.

## Attribution: why your row says an email address

`actor` comes from the validated ID token, via `Principal.actor` in
`d2-signalloom/apps/fe-signalloom/src/api_compat.py`. Dex issues an `email` claim when
the `email` scope is granted, so that is normally what you see. When the claim is absent
the token's `sub` is the only identity available and the row records that instead.

There is no display-name lookup and there deliberately is not one. Substituting a
friendly name would mean putting a value in an audit column that came from a directory
join rather than from the credential that authorised the action — a small, quiet
instance of the same fabrication the invariant exists to prevent.

**The honest limit.** Not every row is attributed yet. A large number of writers still
pass the constant `"demo-actor"`, and a row reading `demo-actor` tells you nothing about
who did anything. The rows that name a real operator today are the ones written by the
privileged-invocation path and the writers converted alongside it. Closing the rest is
ongoing work, and it is worth more than any of the integrity machinery below —
integrity over a record that carries no attribution is a well-witnessed log that says
nothing about who did what.

`src/tests/test_audit_event_types.py` fails the build on any new `_audit_log()` call site
that passes a hardcoded actor, so the population cannot grow.

## Storage: `audit_events` is append-only

Migration `030_audit_events_append_only.sql` installs a statement-level `BEFORE UPDATE OR
DELETE OR TRUNCATE` trigger on `public.audit_events` that unconditionally raises `42501`.
It is enabled `ALWAYS`, not `ORIGIN`, so `session_replication_role = 'replica'` cannot
skip it.

**Do not describe this as immutability.** The migration is explicit about its own scope
and that framing should survive into any summary of it:

* It defends against **the application rewriting its own history** — a compromised API
  process, an injection that reaches the writer, a future migration with a stray `UPDATE`
  in it. All three arrive over the application's own database connection, which is why a
  control on that connection stops all three.
* It is **not a privilege boundary**. The app role owns the table and is a superuser on
  this deployment. Anyone who can reach the database as that role can `ALTER TABLE …
  DISABLE TRIGGER` and then do as they please. The control raises the cost and removes
  the accident; it does not remove the capability.
* A `REVOKE` would have been decoration. Measured on the live cluster, with `UPDATE`
  revoked and the ACL showing it revoked, `has_table_privilege()` still returned true and
  a bare `UPDATE` rewrote every row — because the role is the owner and a superuser.
  Triggers are not privilege checks, so they hold where the grant system does not.

Read the migration's own comment block before writing anything else about this control.
It is the source of truth and it is more careful than a summary can be.

### Resetting the demo

`make demo-signalloom-data-reset` is the sanctioned destructive path, and the only one.
It runs `d2-signalloom/apps/fe-signalloom/src/db/data-reset.sql`, which lifts the guard
explicitly, truncates, and re-arms it — all inside one transaction, so an error on any
`TRUNCATE` rolls the `DISABLE` back with it and the table is never left unguarded.

```bash
make demo-signalloom-data-reset                 # everything
make demo-signalloom-data-reset SERVICE=audit   # audit_events only
```

Two details that are easy to get wrong if you write your own reset:

* The guard has to be lifted around the **whole** body, not just the `audit` branch.
  `audit_events.agent_id` carries a foreign key to `agent_registry`, so
  `SERVICE=agents` reaches the table through `TRUNCATE … CASCADE` and fires the trigger
  just the same.
* It must be re-enabled with `ENABLE ALWAYS`, not a bare `ENABLE`. A bare `ENABLE`
  silently downgrades the trigger to `ORIGIN` and hands back the
  `session_replication_role` bypass every time somebody resets the demo.

The guard lifts itself rather than the trigger carrying a bypass condition, because a
condition an authorised caller can satisfy is a condition an attacker can satisfy.

## Detection: transparency anchoring

`d2-signalloom/apps/fe-signalloom/src/audit_anchor/README.md` is the reference and it
states the limits well. Read it there rather than trusting a paraphrase; what follows is
only the shape and the entry points.

```bash
make audit-anchor-checkpoint   # publish a signed checkpoint over the trail
make audit-anchor-verify       # verify the trail against its anchors (exit 2 = DIVERGED)
make audit-anchor-show         # list published anchors
make audit-anchor-tamper-demo  # prove the verifier detects a real tamper
make audit-anchor-test         # unit tests, no cluster required
```

**What it proves.** Modification and deletion of anchored rows are detectable, and
divergence is localised to a checkpoint window. This is demonstrated rather than
asserted: `scripts/audit-anchor-tamper-demo.sh` writes real rows, anchors them, modifies
one directly in Postgres, shows the verifier going red and naming the window, restores
it, shows it going green, then deletes a row and shows it going red on the count.

**What it does not prove.** It prevents nothing — it is a detector, and someone with
`UPDATE` can still change a row, they simply cannot do it invisibly once it is anchored.
It cannot prove completeness: an event that was never written was never in the log, and
no amount of hashing reveals it. Rows written after the last checkpoint are covered by
nothing, and `verify` reports that count separately rather than folding it into the
verdict — checkpoint cadence is the exposure window and, until row-level chaining lands,
the resolution of the whole control. An empty chain reports `proves_anything: false` and
says so in words, because "intact" over zero checkpoints is the exact overclaim this
component exists to avoid.

One operational trap, since it has now been hit from both directions: `.keys/` is
gitignored and therefore per-checkout, while the cluster it signs for is shared. The
Makefile resolves `KEYS_DIR` through `--git-common-dir`, so it is usually an **absolute
path outside the current working tree** and every consumer must treat it as absolute.
Use `keys_dir_abs` from `scripts/lib/keys.sh` in shell and `$(abspath $(KEYS_DIR))` in
make before any recipe changes directory. `test/audit-anchor-keys-path.bats` covers both
mirror-image failures.

## Adding an audited endpoint

1. Perform the action. If it is a database write, open the transaction.
2. Write the audit row **from the handler**, with `actor=principal.actor`, inside that
   transaction. Never from the client, and never with a hardcoded actor.
3. Record only what this process observed. If you cannot see whether the downstream
   effect succeeded, do not claim it did.
4. If the event type is new, widen the `audit_events` CHECK constraint in a migration and
   add the type to `EVENT_TYPES` **and** `EVENT_COLORS` in
   `dashboard-signalloom/src/views/AuditTrail.tsx`. A type missing from the first cannot
   be filtered; missing from the second it renders grey; missing from the migration,
   `src/tests/test_audit_event_types.py` fails.

## See also

| Topic | Where |
|-------|-------|
| Append-only rationale, measured | `d2-signalloom/apps/fe-signalloom/src/db/migrations/030_audit_events_append_only.sql` |
| Sanctioned reset | `d2-signalloom/apps/fe-signalloom/src/db/data-reset.sql` |
| Anchoring, in full | `d2-signalloom/apps/fe-signalloom/src/audit_anchor/README.md` |
| The one writer | `_audit_log()` in `d2-signalloom/apps/fe-signalloom/src/api_compat.py` |
| Privileged invocations | `_record_privileged_invocation()` in `.../src/demo_runner.py` |
| Guard tests | `.../src/tests/test_audit_event_types.py`, `test_audit_append_only.py` |
| Common questions | [`docs/FAQ.md`](../FAQ.md) |
