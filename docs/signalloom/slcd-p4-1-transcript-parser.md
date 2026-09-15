# SLCD-P4-1 — Zero-Payload Transcript Metadata Parser

**Card:** SLCD-P4-1 · **Phase:** 4 · **Role:** implementation
**Module:** `d2-signalloom/apps/agentmaxxing-host-sensor/transcript.py`
**Suites:** `test_transcript_parser.py` (62), `test_transcript_falsification.py` (15)
**Benchmark:** `scripts/bench_transcript.py`
**Consumes:** SLCD-P4-PRE (confirmed store matrix), SLCD-P1-1 (frozen schema), SLCD-P1-2 (shape-only detection pattern)

---

## 1. What this delivers

A stream-parsing metadata extractor for coding-agent transcripts. It reads the
on-disk stores SLCD-P4-PRE confirmed on this host class and produces exactly the
allowlisted metrics P1-1 froze — step count, token totals, a fixed-arity tool
histogram, an enumerated model family, a session UUID and RFC3339 timestamps —
while carrying **zero bytes of prompt text, assistant response text, tool
arguments, source diffs, file contents or credential values** into its output.

The deliverable is not the parser. It is the parser *plus the argument that its
zero-payload property is true*, in a form that can be refuted.

---

## 2. Why the obvious design is wrong

SLCD-P4-PRE §6.1 states the requirement as:

> Never extract `content`, `text`, `prompt`, `response`, `arguments`, `diff`, or `thinking`.

That is a **deny-list**, and a deny-list of field names cannot be falsified. It
quantifies over the set of bad keys, which is unbounded — every harness release can
add one, and a customer's MCP tool can invent one. A test can confirm those seven
names are absent; it cannot confirm the eighth.

This module quantifies the other way round: over the keys it **does** read, which
are finite and frozen. The provable form of the claim is not *"for all bad keys,
don't read"* but *"for all read keys, they are in this set of eleven"* — and only
the second has something finite to enumerate, which is precisely what makes it
testable.

The practical difference: an unrecognised key here is not *skipped*. It is never
addressed at all, because extraction is a walk over a rule table and never an
iteration over a record.

---

## 3. Design — three independently falsifiable layers

### Layer 1 — a positive field table

`FORMAT_RULES` maps each confirmed `TranscriptFormat` to a frozen `FormatSpec`
carrying a tuple of `FieldRule`s. Each rule names an exact JSON key path:

```python
FieldRule(FieldKind.TOKENS_IN, ("message", "usage", "input_tokens"))
FieldRule(FieldKind.TOOL_NAME, path=("name",), list_path=("message", "content"),
          type_key="type", type_value="tool_use")
```

`_read_path` is the only function in the module that reads a value out of a decoded
record. It follows the key tuple it is handed and returns `None` on any miss. It
cannot enumerate `keys()`, cannot recurse on discovery, and cannot widen its own
path. `test_read_path_cannot_enumerate_record_keys` proves this empirically by
driving the extractor with a `dict` subclass that records every key lookup, then
asserting the touched set is a subset of the allowlist and excludes a planted
`secretCustomerKey`.

**Total addressable surface: 11 distinct key paths for Claude Code, 7 for
Antigravity CLI, 7 for Codex, 3 for Hermes.**

### Layer 2 — a type funnel at the leaves

Every `FieldRule` declares a `FieldKind`, and every `FieldKind` folds through a
bounded coercion whose **codomain** is one of:

| Codomain | Coercion | Behaviour on hostile input |
|---|---|---|
| `int` in `[0, 2**53-1]` | `coerce_count` | a prompt in `input_tokens` becomes `0`; a 4,000-digit integer **clamps** to `MAX_COUNT` |
| `ModelFamily` member | `map_model_identifier` | an unenumerated or oversize string becomes `UNKNOWN` |
| UUID/hex64 string or `None` | `coerce_session_uuid` | a non-UUID is discarded whole, never repaired; case is canonicalised |
| RFC3339 string or `None` | `coerce_rfc3339` | parsed and **re-emitted canonically**, never echoed |
| canonical tool key | `coerce_tool_key` → P1-1's `normalize_tool_name` | unknown and `mcp__*` names → `other_count` |

Three of these are subtler than they look, and each was hardened after the advisor
pass (§8.6):

- **`isinstance(v, int)` is not a bound.** `json` parses arbitrary-precision
  integers, so a 4,000-digit number passes a naive int check and is half a kilobyte
  of attacker-chosen text. `coerce_count` clamps to `MAX_COUNT`, so the output
  carries at most 16 digits whatever the input. (CPython ≥3.11's 4,300-digit
  int↔str cap is a real second line of defence, but it is an interpreter setting a
  deployment can raise, so the clamp must hold alone.)
- **Validation is not sanitisation.** Accepting a timestamp verbatim once it matches
  would pass through the source's *formatting* choices — `Z` vs `+00:00`, zero to
  nine fractional digits — and formatting an attacker controls is a covert channel,
  however narrow. `coerce_rfc3339` parses and re-emits one canonical form, so six
  representations of the same instant produce byte-identical output.
- **`fullmatch`, never `match`.** Python's `$` matches immediately before a
  *trailing* newline, so `re.match(r"^[0-9a-f-]{36}$", uuid + "\n")` **succeeds**.
  Every character class is written `[0-9]` rather than `\d` for the mirror-image
  reason: `\d` is Unicode-aware and would admit Arabic-Indic and fullwidth digits
  into something claiming to be a timestamp.

**No rule has codomain `str`.** A payload therefore cannot be the *output* of any
rule, regardless of what it was as input. `test_no_field_rule_has_a_free_text_codomain`
and `test_no_branch_returns_the_raw_identifier` (AST-based) pin this.

### Layer 3 — a constructor-time invariant

`assert_zero_payload` runs inside `TranscriptExtract.__post_init__` — the single
construction path for the output struct, so no call site can bypass it. It recurses
through dataclasses, mappings, sequences and enums, and requires every string leaf
**and every dict key** to satisfy one of four closed shape predicates:

1. a value of a closed enum this module can emit (`TranscriptFormat`, `ParseStatus`,
   `ModelFamily`, `Harness`), or a member of `SKIP_REASONS`;
2. a member of P1-1's `CANONICAL_TOOL_KEYS`, or a structural field name;
3. a lowercase UUID or 64-hex string;
4. an RFC3339 timestamp.

Anything else raises `TranscriptPayloadViolation` — whose message carries only a
field path, a type name and a length. The exception that reports a leak must not
itself be one; `test_violation_message_carries_no_payload_fragment` pins it.

The walker is an **allow-list on type**, not a deny-list on `str`: `bytes`,
`Decimal`, `Path` and `datetime` all carry text past a check that inspects only
`str`, so any leaf whose type is outside the declared closed set raises.
`test_invariant_rejects_smuggling_types_not_just_strings` covers all four.

**Containment — fail-closed per poll, fail-open per process.** This is a strictly
passive detective sensor; it must never interfere with the agent it observes. So a
tripped invariant must not propagate out and take down the poll loop.
`TranscriptIndexer.poll` catches `TranscriptPayloadViolation` at its boundary,
increments `payload_guard_trips`, drops the bookmark, and returns
`SKIPPED_PAYLOAD_GUARD_TRIPPED`. The whole poll is **discarded rather than partially
emitted** — a mis-wired rule means the other fields in that struct are no longer
trustworthy either. `test_guard_trip_is_contained_and_the_sensor_stays_live` drives
1,000 records with a poison record first, asserts no exception crosses the boundary,
the counter is 1, zero metrics are emitted, and a subsequent poll of a clean file
still works. `test_the_containment_test_is_not_vacuous` pins the complementary half:
without the mutation, that same record does **not** trip the guard.

Note the record ordering in that test is load-bearing, not cosmetic: `_fold` takes
the first non-`None` session UUID it sees, so a poison record placed mid-stream is
shadowed by the clean records before it and never reaches the guard — the test would
then pass for the wrong reason.

---

## 4. What this module does NOT claim

A JSONL record's payload shares a physical line with its metadata. Payload bytes
therefore necessarily cross `read(2)`, and one decoded line is transiently resident
while `json.loads` runs. That is a property of the format, not a design choice.

Two things bound it, and neither eliminates it:

- the reader is chunked at `READ_CHUNK_BYTES` (64 KiB), so the **file** is never
  resident — measured in §7;
- a line above `MAX_LINE_BYTES` (4 MiB) is skipped unparsed and counted.

The falsifiable claim, and the one the proposal's KPI names, is that **zero bytes of
prompt or generated text reach the extracted structure**. A statement about the
process address space would be a different and weaker claim — CPython interns
strings and its arenas are not promptly returned to the OS — so it is not made here.

---

## 5. Coverage of the confirmed stores

| Harness | Store (per P4-PRE §2) | Format | Status |
|---|---|---|---|
| Claude Code | `~/.claude/projects/<slug>/<uuid>.jsonl` | `CLAUDE_JSONL_V1` | implemented, tailing |
| Antigravity CLI | `~/.gemini/antigravity-cli/brain/<uuid>/.../transcript.jsonl` | `ANTIGRAVITY_CLI_JSONL_V1` | implemented, tailing |
| Codex CLI | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | `CODEX_ROLLOUT_JSONL_V1` | implemented, tailing |
| Hermes | `~/.hermes/sessions/request_dump_*.json` | `HERMES_REQUEST_DUMP_V1` | implemented, one-shot |
| Antigravity IDE | `~/.gemini/antigravity/conversations/<uuid>.db` | `ANTIGRAVITY_IDE_SQLITE_V1` | implemented, read-only count |
| OpenCode | `~/.local/share/opencode/opencode.db` | `OPENCODE_SQLITE_V1` | implemented, read-only count |
| CPAI Swarm | `~/.local/share/cpai/` | — | **declared unsupported, tested** |
| Aider | `~/.aider/` (absent on host) | — | **declared unsupported, tested** |

The card names "silently leaving Aider/Hermes transcript parsing unimplemented and
untested, the same gap flagged since P1-PRE" as a failure mode. Hermes is
implemented. Aider and CPAI have no transcript store P4-PRE could confirm on this
host, so rather than leaving a silence, `UNSUPPORTED_HARNESSES` declares them with a
reason and `poll_unsupported_harness` returns an explicit
`SKIPPED_UNSUPPORTED_HARNESS` outcome. `test_unsupported_harnesses_return_an_explicit_named_outcome`
asserts it, and `test_a_supported_harness_is_not_in_the_unsupported_set` keeps that
assertion non-vacuous. **The gap is now a tested outcome rather than an absence.**

### SQLite handling

Both SQLite stores open via `sqlite3.connect("file:<path>?mode=ro", uri=True)` and
issue only statements that are **frozen literals in `SQLITE_RULES`** — `SELECT
COUNT(*)` and a single `id` projection. Nothing is composed from a record, a path or
a caller string. `test_no_sql_statement_references_a_content_column` scans the table
against `PROHIBITED_SQL_TOKENS`. A database whose schema lacks the required tables
fails closed to `SKIPPED_UNRECOGNISED_FORMAT` rather than being guessed at — which
matters because P4-PRE's table names were read from a live DB, not from a schema
contract, and could drift.

---

## 6. Tailing, partial lines, and fail-closed behaviour

`TranscriptBookmark` holds `(last_offset, last_size, last_mtime_ns, inode, partial,
accumulated metrics)` per `(store_root, relative_path)`, per P4-PRE §3.1.

The partial-line rule is the subtle one. `_iter_complete_lines` yields only lines
terminated by `\n`; bytes after the final newline go into `bookmark.partial` and are
**not** yielded. A line truncated mid-write is therefore neither misparsed as a
malformed record (which would lose it and inflate the malformed counter) nor allowed
to abort the poll cycle. `test_partial_trailing_line_is_buffered_not_misparsed`
writes half a valid record with no newline, asserts `records_skipped_malformed == 0`
and `records_parsed` unchanged, then completes the line and asserts it is counted
exactly once.

Other streaming properties, each with a named test:

| Property | Test |
|---|---|
| appends counted exactly once | `test_appends_are_counted_exactly_once` |
| unchanged file reads zero new bytes → `NO_NEW_DATA` | `test_unchanged_file_reads_zero_new_bytes` |
| truncation rewinds the bookmark | `test_truncation_resets_the_bookmark` |
| rotation (inode change) rewinds | `test_rotation_resets_the_bookmark` |
| malformed JSON counted, poll continues | `test_malformed_json_line_counts_and_does_not_abort_the_poll` |
| oversize line skipped unparsed | `test_oversize_line_is_skipped_unparsed` |

**Fail-closed.** Every refusal returns an explicit `ParseStatus` plus a reason from
the closed `SKIP_REASONS` set — never silence and never a guess. A `TranscriptFormat`
with no rule table, or a file whose records carry none of the format's
discriminators, yields `SKIPPED_UNRECOGNISED_FORMAT` with zero metrics. Guessing a
field mapping is the specific thing avoided: a wrong guess can route payload-shaped
content into a metadata field the allowlist was not designed to scrutinise.

**Confinement.** Every open goes through `ConfinedStore.open_relative` →
`openat2.open_beneath` with `RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_XDEV`.
A symlink out of the store, a symlink to a sibling *inside* the store, an absolute
path and a `../` traversal are all refused **by the kernel**, not by a check this
module could get wrong. Four tests, one per case.

**Module boundary.** `transcript.py` imports nothing from `proc.py`. The card names
the risk directly — a shared helper "blurs a boundary where a future refactor of one
could accidentally give the transcript parser a procfs read path it should never
have." `test_transcript_does_not_import_proc` asserts it at the AST, so a future
import fails a test rather than review. No `PROHIBITED_PROC_ENTRIES` member is
removed, weakened, or referenced as a read target.

---

## 7. Throughput and memory measurement

`python3 scripts/bench_transcript.py --mib N` generates a synthetic Claude Code
transcript with realistic record shapes — multi-kilobyte assistant turns, thinking
blocks, `tool_use` blocks with long arguments, `toolUseResult` stdout — which is what
actually makes real transcripts large. The fixture is synthetic by design: a
benchmark pointed at `~/.claude/projects` would be reading live customer payload to
measure a parser built not to.

Measured on this host (Linux 7.1.3, CPython 3.14), 2026-09-15:

| Fixture | Records | Cold parse | Throughput | Peak alloc | **Peak / file size** |
|---|---|---|---|---|---|
| 32.00 MiB | 3,678 | 0.173 s | 185.1 MiB/s | **245.7 KiB** | 0.00750 |
| 128.01 MiB | 14,711 | 0.718 s | 178.3 MiB/s | **256.7 KiB** | 0.00196 |
| 192.00 MiB | 22,066 | 1.108 s | 173.2 MiB/s | **250.5 KiB** | 0.00127 |

**Peak allocation is flat at ~250 KiB across a 6× range of file size.** That is the
measurement that matters: a parser that read the file as one string would show peak
tracking file size, and the ratio column would be ≥ 1.0. It is ~4× the 64 KiB chunk,
which is the chunk plus one decoded record plus the JSON object graph — the
irreducible working set described in §4.

These are the **post-hardening** numbers. Before the §8.6 fixes the same fixtures ran
at 218/228/231 MiB/s with a 222 KiB peak; canonicalising every timestamp through
`datetime.fromisoformat` costs ~22% throughput and ~28 KiB. That is a deliberate
trade — closing a covert channel is worth a fifth of a throughput headroom the
sensor does not need, since a live transcript grows at kilobytes per turn, not
hundreds of megabytes per second. Recorded rather than quietly re-measured, because
a doc table showing the faster pre-fix numbers next to the post-fix code would be a
false claim.

The 192 MiB run also accumulated `tokens_in = 2,758,521,304`, i.e. **above 2³¹−1
(2,147,483,647) in a real end-to-end parse**, with no wraparound. The card names
int32 overflow as an inherited risk from P1-1's own failure modes; the bound here is
`MAX_COUNT = 9007199254740991`, which is byte-identical to the ceiling
`MetricsInfo.validate()` enforces, so a value this parser produces can never be
rejected downstream. Accumulation **saturates** at that bound rather than raising or
wrapping.

Incremental tail after a 1 MiB append to the 192 MiB file: **291 new records in
10.5 ms, peak 205 KiB** — it re-reads only the appended bytes, per P4-PRE §3.1.

`test_working_set_is_bounded_by_chunk_size_not_file_size` re-asserts the memory
property in the unit suite (8 MiB fixture, peak must be under size/4), so the
property is defended in CI and not only in a doc table.

---

## 8. The falsification argument

Two suites, because they refute different claims.

### 8.1 Core falsification — payload in the obvious place

`CorePayloadFalsificationTests` parses a realistically-shaped Claude Code transcript
carrying genuine prompt text, assistant response text, a unified diff and a thinking
block, then searches the **entire serialised output** — `to_json()`, `to_dict()`,
`repr(extract)`, `repr(extract.metrics)` — for any payload token of 8+ characters.
`test_byte_level_zero_payload_kpi` counts leaked bytes with a sliding 16-byte window
and asserts the count is `0`, because the proposal's KPI is literally 0 bytes and a
count is better evidence than an inference.

Non-vacuity is asserted in the same test: `records_parsed > 0`, `step_count > 0`,
`sum(tool_counts) > 0`. A leak test that passes because nothing was parsed proves
nothing.

### 8.2 Structural falsification — payload where no rule looks

Passing §8.1 is consistent with the weaker claim *"we did not see anything sensitive
in the fields we happened to check"*. It is **not** evidence that extraction is
allowlist-based. `StructuralAllowlistFalsificationTests` plants the same payload in
six placements the parser has no rule for:

1. as a **field name** at top level;
2. five levels deep under a key never read;
3. **inside** the allowlisted `message.usage` subtree, at an unexpected sibling key;
4. in an array element beside a legitimate `tool_use` block;
5. in the `model` field — the one field that is genuinely free text in the source;
6. in the `input_tokens` field, where a count is expected.

All six leak nothing, and all six still extract the legitimate fields correctly —
so the parser is not passing by refusing to parse. Two further tests assert that
adding an unknown top-level key, or an unknown key *inside* an allowlisted subtree,
changes **no** output field.

### 8.3 Property-based generalisation

Six hand-written placements are bounded by the imagination of the person who also
wrote the parser. `PropertyBasedLeakTests` removes that bound: 2,000 documents with
payload sentinels injected under randomly-generated key names at random depths, and
at a **randomised insertion position** (order matters — a deny-list fallback that
returns "the first key that is not obviously bad" would pick whichever key was
inserted first). Deterministic seed, so a failure reproduces. Both non-vacuity
directions are asserted: every document must actually contain the sentinel, and
every document must actually parse.

### 8.4 Mutation matrix — each guard observed failing

*A guard never observed failing is an untested claim.* Four mutants were applied to
`transcript.py` **on disk**, the falsification suite run against each, and the file
restored byte-identically (`md5sum` verified):

| Mutant | Change | Suite | Result |
|---|---|---|---|
| M1 | `is_allowlisted_string` → always `True` | falsification | **5 failures** |
| M2 | `map_model_identifier` → `return raw` | falsification | **1 failure, 3 errors** |
| M3 | `coerce_session_uuid` → raw pass-through | falsification | **3 failures** |
| M4 | `_read_path` → deny-list sweep of sibling keys | falsification | **6 failures** |
| M5 | `fullmatch` → `match` (admits a trailing newline) | parser | **1 failure** |
| M6 | timestamp echoed verbatim instead of canonicalised | parser | **1 failure** |
| M7 | containment `except` removed (raise propagates) | falsification | **3 errors** |
| — | restored (`diff -q` byte-identical) | both | **84 passed** |

Five mutation kills are also encoded as permanent in-process tests
(`GuardMutationFalsificationTests`), so the matrix is defended in CI rather than
being a one-off transcript in this document.

### 8.5 Two findings the mutation run produced

**Finding 1 — the fixture was blind to two of its own defects.** On the first run,
M2 and M3 **survived** the falsification suite entirely. The core fixture's `model`
was `claude-opus-5-20260101` (matches a rule, returns early) and its `sessionId` was
a valid UUID (pass-through returns the same value) — so neither mutant reached its
mutated branch, and the suite proved the property only for inputs on which the
property could not fail. This is the *a-regression-test-fixture-can-be-blind-to-its-own-bug*
pattern. Fixed by adding `_pass_through_trap_record()`, whose `model` is short enough
to clear the `MAX_MODEL_ID_CHARS` guard yet matches no rule, and whose `sessionId`
fails the UUID shape check. `test_fixture_reaches_the_pass_through_failing_region`
now asserts both hostility properties **in the test body**, so a later edit cannot
silently move the fixture out of the failing region.

The pre-correction result is kept here deliberately: it is the negative control the
design needed. A suite that killed all four from the start would have left open
whether it discriminates at all.

**Finding 2 — the layers are not redundant, and layer 2 is the load-bearing one for
leaks.** M4 (widening `_read_path` into a deny-list sweep) is **not** killed by the
property-based suite, and this is not a gap — it is a result. A widened read path
feeds sibling values into the same coercions, and the codomain funnel turns a dict,
list or string into `0` or `None`. So M4 produces **wrong metrics, not a payload
leak**; the equivalence tests in §8.2 are the correct detector for it, and they fire
(6 failures). Stated plainly: **layer 2 is independently sufficient against layer 1
failing**, layer 1 exists for metric correctness, and layer 3 backstops both. Claiming
all three are load-bearing against leaks specifically would have been wrong.

### 8.6 Advisor pass — three defects found after the suites were green

A commitment-boundary advisor call against the finished implementation found three
real defects that 77 green tests had not:

1. **`re.match` where `re.fullmatch` was meant.** `is_allowlisted_string` used
   `.match()` with `^...$`. Python's `$` matches before a trailing newline, so
   `"<uuid>\n"` satisfied the predicate — a one-byte channel through a check whose
   entire job is exactness. (`coerce_session_uuid`'s length check happened to block
   it on the extraction path, but the *invariant* was open.) Fixed, mutant M5 added.
2. **Timestamps echoed verbatim.** Validating a shape and then passing the input
   through preserves the source's formatting choices, which an attacker partially
   controls. Now parsed and re-emitted canonically. Mutant M6 added.
3. **The invariant propagated out of `poll`.** In a passive sensor, a guard trip
   would have killed the poll loop — the invariant interfering with the agent it
   promised only to observe. Now contained and counted. Mutant M7 added.

Two further advisor points were checked and found **already handled**, recorded here
so the check is not repeated: `json.JSONDecodeError.doc` carries the whole raw line,
but `_decode_line` catches and discards the exception whole and never formats it;
and unbounded integers are clamped by `coerce_count` rather than merely type-checked.

### 8.7 Scope of the claim — what "zero payload" does and does not mean

"Zero payload" here means **zero verbatim payload bytes in the output struct**. It is
not *zero payload information*. Step counts, token totals, tool histograms and
inter-event timings are a statistical side channel on the work an agent did, and
SLDP-P4-2 already records a differencing attack over aggregate counts as unmitigated.
Anyone reading this document should not over-trust the phrase: the guarantee is about
bytes, and the information-theoretic question is a separate, open one.

---

## 9. Schema conformance

`TranscriptMetrics` is exactly the shape P4-PRE §6.1 froze: `step_count`,
`tokens_in`, `tokens_out`, `tool_counts`, `models`. `tool_counts` keys are exactly
P1-1's 14 `CANONICAL_TOOL_KEYS`; the constructor raises on any non-canonical key, so
a second tool-counting scheme cannot be smuggled in. Tool names route through P1-1's
`normalize_tool_name`, so transcripts and the procfs path can never produce two
different `tool_count` shapes in the same telemetry record depending on data source.

`to_metrics_info()` converts to P1-1's `MetricsInfo`, and
`test_feeds_a_full_coding_agent_telemetry_envelope` drives the result end-to-end into
a validating `CodingAgentTelemetry` envelope — P1-3's wire contract shape.

---

## 10. Evidence

```
$ cd d2-signalloom/apps/agentmaxxing-host-sensor
$ python3 -m unittest test_transcript_parser test_transcript_falsification
Ran 84 tests in 1.871s
OK

$ python3 -m unittest discover -p 'test_*.py'
Ran 340 tests          # 256 at base + 84 new
FAILED (failures=1, expected failures=3)
# the single failure is PRE-EXISTING at base commit fc48150a:
# test_p3_governor_integration.CombinedP2P3OverheadTests
#   AssertionError: 28.079859999999996 not less than 1.0
# a machine-load-dependent P3 duty-cycle KPI, owned by SLCD-P3, untouched here.

$ python3 -m unittest test_negative_security -v
Ran 16 tests — OK          # all 17 PROHIBITED_PROC_ENTRIES still pinned

$ rg -n 'prompt|response|content' models.py
(no output, exit 1)        # zero payload-shaped field names

$ cd ../signal-ingest && go test ./... -run CodingAgentTelemetry
ok  .../signal-ingest/codingagent

$ ./scripts/check-vacuous-assertions.sh
30 pre-existing findings, all in shell scripts; ZERO in transcript.py or either new suite.
```

**Known discrepancy in the card's required-test list.** `python3 -m unittest
test_file_validator -v` reports `Ran 0 tests — NO TESTS RAN`. That file is
pytest-style (module-level `def test_*`, no `unittest.TestCase`), so `unittest`
collects nothing from it. This is **pre-existing at base commit `fc48150a`** and the
file is untouched by this card. Run under its actual runner it is green:

```
$ PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 python3 -m pytest test_file_validator.py -q
16 passed
```

---

## 11. Hard blockers — none encountered

| Blocker | Status |
|---|---|
| A collected field that could carry prompt text, file contents, a credential or process memory | **None.** Every field's codomain is `int`, a closed enum member, or a shape-validated string. |
| A deny-list rather than a structurally-enforced allow-list | **Not present.** `FORMAT_RULES` is a positive table; §8.2/§8.3 falsify the deny-list reading. |
| A credential-detection path that records the value to detect it | **Not present.** This module performs no credential detection; that is `payload_validator.py`'s job, and it is not called from here. |
| Removal of an entry from the `proc.py` prohibited set | **Not done.** `test_prohibited_proc_entries_set_is_unchanged` pins all 17. |
| Absence of a Legitimate Interest Assessment before workstation collection | **Not reached.** This card ships a library with no collector wiring; nothing is enabled. `lawful_basis.py`'s gate is untouched and still governs enablement. |

The last row is the one to carry forward: **this card does not enable workstation
collection.** `transcript.py` is not called from `collector.py` or `sensor.py`. Wiring
it into the live poll loop is a later card and remains gated on the lawful basis.

---

## 12. Open items for downstream cards

1. **Not wired into the collector.** Deliberate — see §11. The integration card must
   pass the `lawful_basis` gate first.
2. **SQLite table names are empirical, not contractual.** P4-PRE read `steps`,
   `session` and `message` off live databases. Both readers fail closed if the schema
   differs, so drift degrades to a skip rather than a wrong parse — but a schema
   change will silently stop collection for those two harnesses. Worth a counter.
3. **Antigravity IDE and OpenCode yield no token counts.** Those schemas expose step
   counts only, per P4-PRE §2. `tokens_in`/`tokens_out` are `0` for them, which is
   indistinguishable from a genuinely idle session at the wire level. If that
   distinction matters downstream, it needs an explicit "not available" signal rather
   than a zero.
4. **Session-UUID → pseudonym conversion is the caller's job.** This module emits the
   raw UUID shape; `derive_session_pseudonym` in `coding_agent_models.py` is what
   produces the 64-hex `session_id` the wire contract requires.
5. **The invariant's predicate is a union, not per-field.** `assert_zero_payload`
   accepts a leaf if *any* of the four shapes matches, so a mis-wired rule putting a
   UUID-shaped value into `models` would pass. Layers 1 and 2 make that unreachable
   today; binding each field to its own declared codomain would close it properly.
6. **Timestamp canonicalisation truncates sub-second precision.** `coerce_rfc3339`
   emits whole seconds. That is deliberate (it is the covert-channel fix), but if a
   downstream consumer needs sub-second ordering it must not get it from here.

### Findings for other cards — surfaced, deliberately not acted on

A `SystemsThinking` leverage analysis over the sensor's payload boundary verified
three things outside this card's scope. They are **not** fixed here — `proc.py` is a
shared file whose changes go through the phase Governor, and `filter.py`/`cli.py`
belong to other cards — but leaving them unrecorded would be worse than noting them:

- **`proc.py`'s `PROHIBITED_PROC_ENTRIES` is a deny-list, and it is unreachable in
  production.** All four call sites pass literals (`"stat"`, `"statm"`, `"status"`,
  `"exe"`), so `_safe_proc_path`'s check can only fire from a test calling it
  directly. The actual enforcement is the *shape of the API* — four named methods,
  no generic read. The list documents intent; it is not a live control. Inverting it
  to `PERMITTED_PROC_ENTRIES` would be cheap and would make it one.
- **`proc.py:136` (`is_pid_alive`) builds its path directly, bypassing
  `_safe_proc_path`.** Benign today, but it is a bypass of the chokepoint inside the
  chokepoint's own file.
- **`cli.py cmd_collect` exports `event.to_dict()` and never imports `filter`.** That
  path is guarded by a *second, independently maintained* copy of the allowlist
  hand-enumerated in `models.ProcessTelemetryEvent.to_dict` — two copies of one
  truth, free to drift. `test_leak_falsification.py` asserts on the *function*
  (`filter_event`), not the *type*, so it structurally cannot catch that path.

None of these is a regression and none is introduced by this card.
