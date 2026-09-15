#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors

"""
Throughput and memory benchmark for the SLCD-P4-1 transcript metadata parser.

The card names "measuring throughput against a small synthetic fixture and never a
realistic multi-megabyte transcript" as a failure mode, because a memory-growth
pattern that only appears at scale is exactly what a small fixture hides. This
generates a realistic Claude Code transcript -- records carrying multi-kilobyte
assistant turns, tool_use blocks with long arguments, and thinking blocks, which is
what makes real transcripts large -- at a configurable size and reports:

  * wall-clock seconds and MiB/s for a cold full parse,
  * peak ``tracemalloc`` allocation during that parse,
  * the peak/file-size ratio (the number that proves it streams),
  * incremental-tail cost for an append after the cold parse.

Usage::

    python3 scripts/bench_transcript.py                 # 32 MiB default
    python3 scripts/bench_transcript.py --mib 128
    python3 scripts/bench_transcript.py --json

The generated fixture is synthetic -- no real customer transcript is read, which
matters because a benchmark that pointed at ``~/.claude/projects`` would be reading
live payload to measure a parser built not to.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import random
import sys
import tempfile
import time
import tracemalloc

PKG_DIR = Path(__file__).resolve().parent.parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

import transcript as T  # noqa: E402

SESSION_UUID = "3f2a1b4c-5d6e-4f70-8a9b-0c1d2e3f4a5b"
MODELS = ("claude-opus-5-20260101", "claude-sonnet-5", "claude-haiku-4-5-20251001")
TOOLS = ("Read", "Edit", "Bash", "Grep", "Glob", "Write", "Task", "WebFetch",
         "mcp__acme__deploy", "TodoWrite")


def _lorem(rng: random.Random, words: int) -> str:
    vocab = ("reconcile", "settlement", "ledger", "idempotent", "retry", "backoff",
             "schema", "migration", "tenant", "invoice", "posting", "batch")
    return " ".join(rng.choice(vocab) for _ in range(words))


def generate_fixture(path: Path, target_bytes: int, seed: int = 20260915) -> int:
    """Write a realistically-shaped Claude Code JSONL transcript of ~target_bytes."""
    rng = random.Random(seed)
    written = 0
    with open(path, "w", encoding="utf-8") as handle:
        step = 0
        while written < target_bytes:
            step += 1
            record = {
                "sessionId": SESSION_UUID,
                "timestamp": f"2026-09-15T{step % 24:02d}:{step % 60:02d}:00.000Z",
                "type": "assistant" if step % 3 else "user",
                "uuid": f"{step:08x}-0000-4000-8000-000000000000",
                "cwd": "/home/operator/customer-repo",
                "parentUuid": f"{max(0, step - 1):08x}-0000-4000-8000-000000000000",
                "message": {
                    "id": f"msg_{step:012d}",
                    "model": rng.choice(MODELS),
                    "role": "assistant",
                    "usage": {
                        "input_tokens": rng.randint(1000, 200000),
                        "output_tokens": rng.randint(50, 8000),
                        "cache_read_input_tokens": rng.randint(0, 50000),
                    },
                    "content": [
                        {"type": "thinking", "thinking": _lorem(rng, 200)},
                        {"type": "text", "text": _lorem(rng, 400)},
                        {
                            "type": "tool_use",
                            "id": f"toolu_{step:012d}",
                            "name": rng.choice(TOOLS),
                            "input": {"command": _lorem(rng, 120),
                                      "file_path": "/home/operator/customer-repo/x.go"},
                        },
                    ],
                },
                "toolUseResult": {"stdout": _lorem(rng, 300), "stderr": ""},
            }
            line = json.dumps(record) + "\n"
            handle.write(line)
            written += len(line)
    return path.stat().st_size


def run(target_mib: int) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = root / "bench.jsonl"
        size = generate_fixture(fixture, target_mib * 1024 * 1024)

        indexer = T.TranscriptIndexer()
        tracemalloc.start()
        start = time.perf_counter()
        with T.ConfinedStore(root) as store:
            extract = indexer.poll(store, "bench.jsonl", T.TranscriptFormat.CLAUDE_JSONL_V1)
        elapsed = time.perf_counter() - start
        _current, peak = tracemalloc.get_traced_memory()
        tracemalloc.stop()

        # Incremental tail: append 1 MiB and re-poll the same bookmark.
        append_start_size = fixture.stat().st_size
        with open(fixture, "a", encoding="utf-8") as handle:
            rng = random.Random(7)
            appended = 0
            while appended < 1024 * 1024:
                line = json.dumps({
                    "sessionId": SESSION_UUID,
                    "timestamp": "2026-09-15T23:59:59Z",
                    "type": "assistant",
                    "message": {"model": "claude-opus-5", "role": "assistant",
                                "usage": {"input_tokens": 10, "output_tokens": 2},
                                "content": [{"type": "text", "text": _lorem(rng, 400)},
                                            {"type": "tool_use", "name": "Bash"}]},
                }) + "\n"
                handle.write(line)
                appended += len(line)

        tracemalloc.start()
        tail_start = time.perf_counter()
        with T.ConfinedStore(root) as store:
            tail = indexer.poll(store, "bench.jsonl", T.TranscriptFormat.CLAUDE_JSONL_V1)
        tail_elapsed = time.perf_counter() - tail_start
        _tc, tail_peak = tracemalloc.get_traced_memory()
        tracemalloc.stop()

        return {
            "file_bytes": size,
            "file_mib": round(size / 1048576, 2),
            "records_parsed": extract.records_parsed,
            "cold_parse_seconds": round(elapsed, 3),
            "cold_throughput_mib_per_s": round((size / 1048576) / elapsed, 1),
            "cold_records_per_s": int(extract.records_parsed / elapsed),
            "cold_peak_alloc_bytes": peak,
            "cold_peak_alloc_kib": round(peak / 1024, 1),
            "peak_to_file_ratio": round(peak / size, 5),
            "read_chunk_bytes": T.READ_CHUNK_BYTES,
            "tail_appended_bytes": fixture.stat().st_size - append_start_size,
            "tail_seconds": round(tail_elapsed, 4),
            "tail_peak_alloc_kib": round(tail_peak / 1024, 1),
            "tail_new_records": tail.records_parsed - extract.records_parsed,
            "step_count": tail.metrics.step_count,
            "tokens_in": tail.metrics.tokens_in,
            "tokens_out": tail.metrics.tokens_out,
            "models": list(tail.metrics.models),
        }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mib", type=int, default=32, help="fixture size in MiB (default 32)")
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    args = parser.parse_args(argv)

    result = run(args.mib)
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0

    print(f"[SLCD-P4-1 transcript parser benchmark]")
    print(f"  fixture               : {result['file_mib']} MiB, "
          f"{result['records_parsed']} records")
    print(f"  cold parse            : {result['cold_parse_seconds']}s "
          f"({result['cold_throughput_mib_per_s']} MiB/s, "
          f"{result['cold_records_per_s']} rec/s)")
    print(f"  cold peak allocation  : {result['cold_peak_alloc_kib']} KiB "
          f"(chunk size {result['read_chunk_bytes'] // 1024} KiB)")
    print(f"  peak / file size      : {result['peak_to_file_ratio']} "
          f"(a whole-file read would be >= 1.0)")
    print(f"  incremental tail      : {result['tail_new_records']} new records in "
          f"{result['tail_seconds']}s, peak {result['tail_peak_alloc_kib']} KiB")
    print(f"  extracted             : step_count={result['step_count']} "
          f"tokens_in={result['tokens_in']} tokens_out={result['tokens_out']} "
          f"models={result['models']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
