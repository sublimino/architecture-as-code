# Audit-log transparency anchoring

Periodically commit to the contents of `public.audit_events` and publish that
commitment somewhere the application cannot reach, so that later modification or
deletion of anchored rows is detectable.

## Why the anchor is the control, not the chain

Hash-chaining a log does not prevent tampering. It detects it — and only if the
chain head is published somewhere the tamperer cannot reach.

Git makes this unavoidable. `git commit --amend` followed by a force-push
rewrites history and every hash downstream of it, and the result is perfectly
self-consistent: every parent pointer checks out, every object hashes correctly.
The only reason anyone notices is that **other people hold clones**. The chain is
not the protection. The independent witness is.

An anchor stored in the same database as the rows is a clone held by the same
person. It buys nothing. So the property this component preserves is narrow and
specific:

> Rewriting history must also require rewriting the anchor, and the anchor must
> not be in the attacker's control.

Everything else here — the Merkle tree, the DSSE envelope, the CLI — is
packaging around that one sentence.

## What it does

    checkpoint   read the audit table up to a safe boundary, build the next
                 checkpoint in the chain, sign it, publish it
    verify       recompute every anchored window from the live table and
                 compare against the published anchors
    show         list the published anchors

```bash
cd d2-signalloom/apps/fe-signalloom/src
python -m audit_anchor --dsn "$DATABASE_URL" checkpoint
python -m audit_anchor --dsn "$DATABASE_URL" verify        # exit 0 / 2
```

Exit codes: `0` intact, `2` **diverged**, `1` could not run. 2 is distinct from 1
deliberately — a verifier that exits non-zero for both "tampering detected" and
"I could not reach the database" trains its operator to treat red as noise, and
the one time it matters they will treat it as noise too.

## Canonical serialisation

The full rules are in `canonical.py`'s module docstring, which is written so a Go
or Rust verifier can be built from it alone. In brief:

* **Row encoding** is tag-and-length framed — `0x00` for NULL, `0x01 ||
  uint64_be(len) || utf8` otherwise — over a fixed field order, prefixed with an
  encoding version. Length prefixing (the same reasoning as DSSE's PAE) is what
  stops an actor who controls their own name from moving a field boundary and
  making a tampered row serialise identically to an honest one.
* **Timestamps** are `to_char(timestamp AT TIME ZONE 'UTC', ...)` — UTC, ISO
  8601, always six fractional digits. `timestamptz::text` follows the session's
  TimeZone and DateStyle, so two honest verifiers with different session settings
  would otherwise serialise different bytes from the same row.
* **JSONB** is canonicalised per RFC 8785 with keys sorted by UTF-16 code unit
  (*not* code point — `sort_keys=True` is not conformant), with **one deliberate
  deviation**: numbers are preserved as their literal token rather than
  reformatted as ECMAScript doubles. jsonb stores `numeric`, so `1.0` and `1.00`
  are different stored values that a float round-trip would collapse, and any
  integer above 2^53 would be silently corrupted.
* **Every column is projected to text in SQL**, so no client driver sits inside
  the trust chain.
* **Row order** is `(ts, id)` compared bytewise, sorted in the client — never
  `ORDER BY`, whose result for `text` depends on the database's collation.

## Scoping, and rows arriving during a checkpoint

Each checkpoint commits to one window `(previous boundary, this boundary]` and
carries the digest of the checkpoint before it, so checkpoints chain even though
rows do not yet. Verification is per-window and divergence is reported against
the specific window it began in.

The boundary is the subtle part. `audit_events.timestamp` defaults to `NOW()`,
and **`NOW()` in Postgres is transaction start time, not statement time** — a
transaction that began thirty seconds ago and commits now writes a row stamped
thirty seconds in the past. "Anchor everything up to `now()`" is therefore wrong:
honest rows keep landing behind the boundary afterwards, each one reported as a
back-dated insertion. False positives are how a verifier gets switched off.

`reader.choose_boundary` resolves this structurally rather than by hoping. Any
row an in-flight transaction can still write carries a timestamp of at least that
transaction's start time, so a boundary strictly below the oldest in-flight
transaction's start time is unreachable by every writer that currently exists —
and a writer that does not exist yet will start later still. Back-dating into an
anchored window then requires a direct `UPDATE` or a forged timestamp, which is
exactly the tampering we want reported.

Where the role cannot see other sessions' `xact_start` (masked without
`pg_read_all_stats`), the clamp is unavailable and only a settle lag applies.
That is a timeout assumption rather than a proof, so the basis is recorded in
`boundary_basis` **inside the signed predicate** — an auditor can tell from the
artefact alone whether a checkpoint rests on a proof or an assumption.

## The anchor

Checkpoints are published as **in-toto Statements in DSSE envelopes**, signed
with the ed25519 key at `.keys/witness.pem` — the same key
`scripts/attested-test.sh` already uses to sign attestations into Archivista.

This reuses what the repository already runs rather than adding anything.
ControlPlane sponsors Witness and Archivista; the backend slice
(`d2-osramp-apps/components/backend/`) deploys Archivista at
`svc/osramp-archivista:8082` with its own MySQL and MinIO, in a different
namespace under different credentials, which the signalloom Postgres role has no
route to. **No new dependency was added**: DSSE is a length-prefixed encoding
plus an ed25519 signature, and `cryptography` is already present via
`PyJWT[crypto]`.

Two transports, one artefact format:

* `ArchivistaAnchorStore` — the intended anchor. Content-addressed, so altering a
  stored envelope changes its address rather than its contents.
* `FileAnchorStore` — fallback. Weaker, and it should be said plainly: its only
  strength is the filesystem permissions on the directory. The bytes are
  identical, so the same files upload to Archivista unchanged.

Selected by `ARCHIVISTA_URL` / `AUDIT_ANCHOR_DIR`; the CLI always prints which
store it used, because a checkpoint anchored to a transparency log and one
anchored to a local directory are not the same evidence.

### Where the signing key lives

`.keys/` is gitignored and therefore **per-checkout**, while the cluster it
signs for is shared — so a worktree normally has no keys of its own and reaches
the main checkout's. The Makefile resolves this through `--git-common-dir`
(`scripts/lib/keys.sh`), which means `KEYS_DIR` is usually an **absolute path
outside the current working tree**, and every consumer must honour it as
absolute.

Two mirror-image ways to get that wrong, both of which shipped and are now
covered by `test/audit-anchor-keys-path.bats`: joining an absolute `KEYS_DIR`
onto a base swallows its leading slash, and passing a relative one through a
`cd` resolves it against the wrong directory. Use `keys_dir_abs` from
`scripts/lib/keys.sh` in shell, and `$(abspath $(KEYS_DIR))` in make before any
recipe changes directory.

## What this proves — and what it does not

**It detects modification and deletion of anchored rows.** Proven live, not
merely asserted: `scripts/audit-anchor-tamper-demo.sh` writes rows to the real
table, anchors them, modifies a row directly in Postgres, and shows the verifier
going red and naming the affected checkpoint; then restores the row and shows it
going green again; then deletes a row and shows it going red on the row count.

It does **not**:

* **Prevent anything.** It is a detector. Someone with `UPDATE` on the table can
  still change a row; they simply cannot do it invisibly once it is anchored.
* **Prove completeness.** An event that was never written was never in the log,
  and no amount of hashing will reveal it. Anchoring says "these rows are the
  rows that were here", not "these are all the events that happened". Audit
  *coverage* — every consequential action having a call site that writes a row —
  is a separate and prior concern.
* **Protect unanchored rows.** Rows written after the last checkpoint are covered
  by nothing. `verify` reports that count separately and never folds it into the
  verdict. Checkpoint cadence is the exposure window.
* **Localise below checkpoint granularity.** Until row-level chaining lands,
  divergence resolves to a window, not a row. Cadence is the resolution of the
  whole control.
* **Prove anything when nothing is anchored.** An empty chain reports
  `proves_anything: false` and the CLI says so in words, because "intact" over
  zero checkpoints is the exact overclaim this component exists to avoid.
* **Survive loss of the signing key.** Someone holding `.keys/witness.pem` can
  forge a consistent replacement chain. The key must not live where the database
  does.
* **Mean much while attribution is missing.** At time of writing every audit row
  records `actor = "demo-actor"`. Integrity over a record that carries no
  attribution is a well-witnessed log that says nothing about who did what. That
  work is being done separately and it is worth more than this is.

### Not yet verified

The Archivista transport is implemented against the documented API and exercised
in tests against a stub implementing those endpoints — enough to catch our own
wire-format bugs, **not** enough to prove the real server agrees with our reading
of its API. The backend slice holding Archivista is not deployed in the cluster
this was built against, so that path remains unexercised against the real thing.
The file transport is the one that has actually been run end to end.

## For the row-level chaining work

When per-row hash chaining lands, this component needs three things from it and
offers two in return.

Needs:

1. **Do not change the canonical row encoding.** If a hash column is added to
   `audit_events`, it must be *excluded* from `ROW_FIELD_ORDER`, or every
   previously published digest becomes unreproducible. Adding a column that is
   included means bumping `ROW_ENCODING_VERSION`, and old checkpoints can then
   only be verified by the old encoding.
2. **Reuse `canonical.encode_row`** as the input to the row chain rather than
   writing a second serialisation. Two serialisations of the same rows in one
   repository will eventually disagree, and the first person to notice will be an
   auditor.
3. **Decide the ordering key deliberately.** Row chaining needs a total order;
   this component uses `(ts, id)`. If the chain uses insertion order instead, the
   two commit to different sequences over the same rows.

Offers:

1. **`merkle.inclusion_proof`** — already implemented and tested for every index
   at tree sizes 1–8. This is what lets a single row be proven to belong to a
   published checkpoint without shipping the window.
2. **Checkpoint granularity as the fallback.** Row chaining localises to a row
   but is only as trustworthy as its anchor; these checkpoints are the anchor.
   The two compose: the chain says *which row*, the checkpoint says *and this is
   witnessed externally*.

## Tests

    PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 python -m pytest tests/test_audit_anchor_*.py

128 tests: canonical serialisation (every ambiguity above pinned as a test),
RFC 6962 tree hashing (including the published Certificate Transparency vectors,
which come from an unrelated codebase and are the check that we implemented the
RFC rather than a plausible tree of our own), checkpoint chaining and divergence
localisation, and DSSE signing with both transports.
