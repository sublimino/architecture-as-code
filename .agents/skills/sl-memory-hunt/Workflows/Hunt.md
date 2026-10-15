# Workflow: Hunt a memory problem

`T=.agents/skills/sl-memory-hunt/Tools/memory-hunt.sh`. The cluster is shared, so stay
read-only: `kubectl get/describe/logs` and `crictl` on the node, no exec into app containers.

## 1. Detect

```bash
$T scan -A                 # exit 1 = something is OOMing or restart-looping
$T scan -n fe-signalloom --json | jq '.containers[] | {pod, container, restarts, last_oom_at, memory_limit}'
```

A `restarts` flag without `oom` is a restart loop with another cause (`Completed`, `Error`).
Check `kubectl logs --previous` before treating it as memory.

## 2. Measure

```bash
$T env    --pod <pod> -n <ns>                                   # GOMAXPROCS, GOMEMLIMIT
$T sample --pod <pod> -n <ns> --interval 15 --duration 120      # idle
$T sample --pod <pod> -n <ns> --interval 5  --duration 60 --json > /tmp/load1.json   # under one load
```

For a bare process, use `sample --pid <pid>`. Keep every `--json` run. They are your evidence.

## 3. Classify

Follow [`../References/Classification.md`](../References/Classification.md). Run at least
one concurrent-load series (N ≥ 2) before you call something a leak.

## 4. Fix

- **Stopgap** (optional, only to stop the bleeding): raise the limit in its own commit, and
  say in the message that it is a stopgap.
- **Root fix**: bound the fan-out or fix the leak at its source.
- **Retire the stopgap**: put the limit back to its sized value once step 5 passes.

## 5. Prove

Add a test that measures bytes (peak MiB under the concurrent load) and asserts a ceiling.
Show it failing under a mutant that restores the old behaviour, then passing on the fix.
Re-sample live after deploy and compare the peak against the step 2 baseline.

## 6. Hand off

With a measured hot spot, invoke `ripwire-perf-target` to locate the code.
