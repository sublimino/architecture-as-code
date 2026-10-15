---
name: sl-memory-hunt
description: "Find, measure and classify memory problems in #partner-signal-loom workloads: OOMKilled containers, silent restart loops, working-set growth, leak versus concurrency fan-out. Samples distroless containers from the kind node via crictl, and bare host processes via /proc. USE WHEN OOMKilled, OOM, out of memory, restart loop, restartCount, pod restarting, memory leak, working set, Weave 502, signal-ingest memory, GOMAXPROCS, or sl-memory-hunt."
---

# sl-memory-hunt

Memory triage for the **Signal Loom** (`#partner-signal-loom`) platform. The tool finds the
container, measures it over time, and gives you the numbers to classify the cause. The
fix is yours. The `ripwire-perf-target` skill takes over once the hot spot is measured.

## Ideal state

The work is done when all of these hold:

1. **Every OOM loop is named.** `scan` reports each container whose last termination was
   `OOMKilled` (init containers included) or whose `restartCount` exceeds the threshold.
   Output includes pod, container, restart count, last OOM time, and memory limit. Nothing
   restarting is waved through because the pod reads `Running`.
2. **Memory is a series, never a point.** The working set was sampled at an interval across
   idle, a single load, and N concurrent loads. Peak, time of peak and peak as a percentage
   of the limit are recorded.
3. **The cause is classified with evidence.** Either a *leak* (grows with time and request
   count, never returns) or *fan-out* (peak scales with concurrent readers × data size,
   returns after the load). See [`References/Classification.md`](References/Classification.md).
4. **Stopgap and root fix are separate, and the stopgap is retired.** A raised limit is
   recorded as a stopgap. Once the root fix is proven, the limit returns to its sized value
   in its own commit.
5. **A byte-measuring test pins the fix.** The test asserts a peak in bytes and fails under a
   mutant that restores the old behaviour. An exit-code-only test does not count.

## Tool

[`Tools/memory-hunt.sh`](Tools/memory-hunt.sh). Exit codes: `0` clean/ok, `1` scan found an
OOM or restart loop, `2` usage, `3` cluster/target error or zero samples.

```bash
T=.agents/skills/sl-memory-hunt/Tools/memory-hunt.sh
$T scan -n fe-signalloom                 # or -A; --threshold N (default 5); --json
$T sample --pod signal-ingest -n fe-signalloom --interval 15 --duration 120
$T sample --pid 12345 --interval 1 --duration 30      # bare process: VmRSS series + VmHWM
$T env --pod signal-ingest -n fe-signalloom           # GOMAXPROCS / GOMEMLIMIT, image + runtime
```

`--pod` takes an exact name or a unique prefix of a Running pod (OOM restarts and rollouts
churn names). Injectable for tests: `KUBECTL`, `DOCKER`, `CRICTL_NODE`, `PROC_ROOT`, `SLEEP`.

`sl-silent-failure-audit` runs `scan -A` as its check 5 (`AUDIT_RESTART_THRESHOLD`, default 5).

## Workflow

[`Workflows/Hunt.md`](Workflows/Hunt.md): detect → measure → classify → fix → prove → hand off.

## Gotchas

- **`Running` hides an OOM loop.** `CrashLoopBackOff` only shows in the short waiting window
  between restarts. On 2026-10-15 signal-ingest was OOMKilled at 2Gi 28 times in 6.5h and
  the only visible symptom was a Weave 502. Read `.status.containerStatuses[].restartCount`
  and `.lastState.terminated.reason == "OOMKilled"` with its `finishedAt`.
- **Distroless images have no shell.** `kubectl exec ... cat /sys/fs/cgroup/...` fails, and a
  check that negates that failure passes for the wrong reason. Measure from the node:
  `docker exec <kind-node> crictl stats -o json <cid>` → `.stats[0].memory.workingSetBytes.value`.
- **One sample misleads.** signal-ingest read 194 MiB, then 1.7 GiB while idle, then it was
  killed. Only a 15s series showed the shape.
- **`kubectl top` may not exist.** kind-osramp has no metrics-server. crictl on the node does
  not need one.
- **Image env changes behaviour.** Go sizes its scheduler to the node's cores unless
  `GOMAXPROCS` is set. On a 24-core host, FrostDB fanned each scan out 24 ways. Read it with
  `crictl inspecti <image> | jq .info.imageSpec.config.Env`. The `env` command shows it.
- **Memory that tracks total data size points to fan-out, not a leak.** Same request, bigger
  store, bigger peak: suspect concurrency × data size first. `GOMAXPROCS=2` took a 2-viewer
  peak from 6.7 GiB to 42 MiB. Measure peak under N concurrent loads to tell the two apart.
- **Raising the limit is a stopgap.** 2Gi → 4Gi → 8Gi each bought time and fixed nothing.
  Remove the headroom once the root fix is proven (signal-ingest went back to 2Gi in `0fc945d49`).
- **Concurrent headless Chrome needs distinct `--user-data-dir`.** Two viewers sharing a
  profile collapse into one process, so the "N concurrent loads" were really one.
- **Bare processes work too.** For a host process (a Go binary under test, a local server),
  sample `/proc/<pid>/status` `VmRSS`. Read `VmHWM` for the high-water mark missed between ticks.
- **The proof has to measure bytes.** The fix's test asserts a peak in MiB and fails under the
  mutant (`GOMAXPROCS=24`: peak 18.7 → 187.7 MiB). A test that only checks exit 0 passes both ways.

## Hand-off

Measure the hot spot first (a peak scaling with concurrency or data size, a profile, or heap dump).
Hand it to **`ripwire-perf-target`** to locate the code path. This skill does not read code to find the
cause. It measures, and the measurement decides what to look at.
