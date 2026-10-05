# Running the test suite twice at once

Two concurrent runs of the acceptance set must both pass. This page is how to
check that, and the rules that keep it true.

## Commands

```bash
make test-isolation-audit        # static gate: fixed ports and /tmp paths
make test-isolation-audit-test   # the audit's own suites + the free_port library
make test-parallel-acceptance    # two real acceptance passes, concurrently (~10-15 min)
```

`scripts/parallel-acceptance.sh` exits 0 only if **both** children pass. It also
fails when the two runs disagree on their totals, because two runs of the same
tree at the same commit that produce different counts have interfered with each
other whatever their exit codes say.

## The three rules

**1. Never hardcode a port.** Ask the kernel.

```bash
load "${BATS_TEST_DIRNAME}/lib/freeport.bash"
port="$(free_port)"
```

```go
ln, err := net.Listen("tcp", "127.0.0.1:0")   // or httptest.NewServer
```

Better still, where the caller can bind `:0` itself and read the port back
afterwards, do that — it has no ask-then-bind window at all.
`test/afm-rbac-exporter-push.bats` binds `("127.0.0.1", 0)` and writes the
chosen ports to a `ports.env` the test then sources. That is the pattern to
copy.

**2. Never hardcode a path under `/tmp`.** Use `$BATS_TEST_TMPDIR` in bats and
`t.TempDir()` in Go. Both are per-run and both are cleaned up for you.

**3. Scale a timeout, never an assertion.** If a test is flaky under load,
multiply its wall-clock budget by `TEST_TIMEOUT_SCALE` and leave what it checks
alone. A test that waits longer still fails on a real regression; a test whose
assertion was weakened does not.

## Readiness probes: `wait_for_listen`, not `wait_for_port`

`test/lib/freeport.bash` has both and they are not interchangeable.

| helper | how it checks | use for |
| --- | --- | --- |
| `wait_for_listen PORT [s]` | polls `ss` for LISTEN state, never connects | one-shot listeners (`nc -l` without `-k`) |
| `wait_for_port HOST PORT [s]` | dials the port | servers that accept repeatedly |

`nc -l` without `-k` accepts exactly one connection and exits, so a probe that
dials it *consumes the listener* and the thing under test then finds nothing
bound. When that happened in `test/p2-dualcluster-preflight.bats` the symptom
was not a failure — bats printed `Executed 22 instead of expected 23` and the
test silently disappeared.

## Why the audit has an allowlist

Most fixed port literals in the tree are not hazards. `ConntrackTuple{SrcPort:
54321}`, a `ContainerPort` in a Pod spec, a `/proc/net/tcp` fixture, a `dstPort`
handed to the egress classifier, an example DSN in a how-to-run comment — none
of these bind or create anything. 70 of the 91 raw hits are in that category.

So `scripts/test-isolation-audit.sh` reports everything and
`test/fixtures/test-isolation-allowlist.txt` records why each one is safe. Four
reasons are admissible:

- **inert** — test data; nothing binds it, nothing creates it
- **overridable** — an env-var default (`${GOCACHE:-/tmp/gocache}`) the harness
  points elsewhere per run
- **unique** — a prefix completed at run time by `$$`, `%d` or a nonce
- **in-container** — resolved inside a container, not on the host

"It happens to work today" is not one of them. An entry with no reason at all is
exit 2, not a pass.

## What each concurrent run gets to itself

`scripts/parallel-acceptance.sh` gives each child its own `GOCACHE`,
`GOMODCACHE`, `GOPATH`, `TMPDIR`, output directory, and `TEST_PORT_BASE`. Go's
caches are lock-protected so sharing them would be *safe*, but it would
serialise the two runs on the lock and hide timing interference behind cache
hits — separate caches make the test honest.

`TEST_PORT_BASE` (21000 for A, 41000 for B) is advisory. Nothing in the tree
needs it, because the convention is `free_port()` / `:0`, which needs no base.
It is exported so a suite that genuinely cannot ask the kernel has somewhere to
start that is not shared.

## Known load-sensitive tests

| test | budget | notes |
| --- | --- | --- |
| `TestSpoolRetainsBatchesAcrossIngestOutage` (`stun-sentinel/pkg/correlator/sender_test.go`) | 2s × scale | was 50 × 10ms = 500ms. Measured margin under load: mean 270ms, worst 295ms — 1.7× headroom, down from 4× on a quiet host. |
| `TestLocalFreezeWritesAWardenCaptureWithTheTwoSpecAnalogues` (`signalloom-stun-sentinel/capture_test.go`) | 500ms × scale freeze deadline, 5s × scale capture wait | **The reported failure has not been reproduced locally** — 20/20 at the original 50ms deadline under loadavg 48, and 20/20 under loadavg 65 with four concurrent Go suites. The raise is precautionary: the fake kernel in `simulateKernel()` is a userspace goroutine on a 1ms poll, so its headroom is scheduling-dependent. |
| `TestBatchChainHeaders` (`sender_test.go:104`) | **not scaled** | Same class, still a fixed 50 × 20ms. Left for the package owner. |

Pure CPU load does not reproduce either failure — base code passed 10/10 at
loadavg 121. What reproduced the spool one was CPU **plus** `fsync` churn plus
fork churn: 24× `yes`, 16 create/write/fsync/unlink loops, 8 fork loops on 24
cores. Even then it was roughly 1 failure in 30, which is why the margin was
measured directly rather than inferred from a pass count.
