# Classifying a memory problem: leak versus fan-out

Both end in `OOMKilled`, and raising the limit postpones both. They need different fixes,
so classify the cause before you change anything.

| Signal | Leak | Concurrency / fan-out |
| :-- | :-- | :-- |
| Idle working set over time | Climbs and never returns | Flat between loads |
| One request, then idle | Steps up and stays up | Spikes, then returns |
| Peak vs total stored data | Unrelated | Scales with it |
| Peak vs concurrent readers | Roughly additive per request | Multiplies (readers × workers × data) |
| Peak vs `GOMAXPROCS` / worker count | Unrelated | Scales with it |
| `VmHWM` vs latest `VmRSS` (bare process) | Both high | `VmHWM` far above `VmRSS` |

## Measurement protocol

1. **Idle baseline**: `sample --duration 120 --interval 15` with no traffic.
2. **Single load**: the same sample while one client drives the suspect path (one dashboard
   viewer, one `curl` loop).
3. **N concurrent loads**: repeat with N = 2 and N = 4. Headless Chrome viewers each need
   their own `--user-data-dir`, or they share one process.
4. **Vary data size** if you can (a bigger fixture store). Fan-out peaks grow with it.
5. Record peak, peak time and peak % of limit for each run. Compare peaks, not single samples.

## The 2026-10-15 signal-ingest case

- Symptom: Weave 502. signal-ingest OOMKilled at 2Gi, 28 restarts in 6.5h, unnoticed.
- Series: 194 MiB → 1.7 GiB idle → killed.
- Image env: no `GOMAXPROCS`, so Go used all 24 node cores and FrostDB fanned each scan out
  24 ways over a 485 MB Parquet store. Classification: fan-out, not a leak.
- Stopgaps: limit 4Gi, then 8Gi (`0c585d02f`, `e4b6d133e`).
- Root fix: bound the scan fan-out and set `GOMAXPROCS=2` (`02c3f16a6`). The 2-viewer peak
  went from 6.7 GiB to 42 MiB.
- Stopgap retired: limit back to 2Gi (`0fc945d49`).
- Proof: a byte-measuring test, peak 18.7 MiB, which fails under the mutant `GOMAXPROCS=24`
  (187.7 MiB).
