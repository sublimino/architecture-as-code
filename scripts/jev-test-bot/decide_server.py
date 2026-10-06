#!/usr/bin/env python3
"""Serve Jev System One decisions over stdin/stdout JSON lines.

The browser driver is JavaScript, because driving a real Chromium is. The
decision model lives in `bot.py` (`JevClient`), because that is where the
TypeSafe request shape, the API-key resolution order and the calibrated
offline simulator already are. Reimplementing any of that in JS would give
two decision models that drift apart silently — the browser run and the fetch
run would then be exploring by different rules while reporting in the same
format.

So the driver spawns this, writes one request per line, and reads one response
per line. `bot.py` is imported, not invoked: its CLI contract is untouched.

Protocol. One JSON object per line in, one per line out, in order.

  in   {"id": 7, "snapshot": {"url":…, "title":…, "text":…, "elements":[…]},
         "intent": "…", "area": "/risk", "recent_actions": [...],
         "visited_urls": ["/agents", …]}
  out  {"id": 7, "operation": "CLICK", "target": {…}, "confidence": 0.95,
         "mock": true}
  out  {"id": 7, "error": "…"}            on a malformed request

A request that cannot be parsed as JSON at all gets `{"id": null, "error": …}`
rather than closing the stream: one bad line must not take the run with it.

Usage:
    decide_server.py [--mock]

`--mock` forces the calibrated simulator. Without it the key-resolution order
in `bot.py` applies, and `JevClient` falls back to the simulator by itself if
no key is available or the API call fails.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from bot import JevClient, PageSnapshot, get_jev_api_key  # noqa: E402


def snapshot_from(payload: dict) -> PageSnapshot:
    return PageSnapshot(
        url=payload.get("url") or "",
        status_code=int(payload.get("status_code") or 200),
        title=payload.get("title") or "",
        text=payload.get("text") or "",
        elements=list(payload.get("elements") or []),
    )


def serve(client: JevClient, stdin, stdout) -> int:
    for line in stdin:
        line = line.strip()
        if not line:
            continue
        request_id = None
        try:
            request = json.loads(line)
            request_id = request.get("id")
            decision = client.decide(
                snapshot_from(request.get("snapshot") or {}),
                request.get("intent") or "",
                request.get("area") or "/",
                list(request.get("recent_actions") or []),
                set(request.get("visited_urls") or []),
            )
            response = {
                "id": request_id,
                "operation": decision.get("operation"),
                "target": decision.get("target"),
                "confidence": decision.get("confidence"),
                "mock": decision.get("mock", True),
            }
        except Exception as exc:  # noqa: BLE001 — any failure must answer, not hang
            response = {"id": request_id, "error": f"{type(exc).__name__}: {exc}"}
        stdout.write(json.dumps(response) + "\n")
        stdout.flush()
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--mock",
        action="store_true",
        help="Force the calibrated System One simulator instead of a live TypeSafe call",
    )
    args = parser.parse_args(argv)

    client = JevClient(api_key=None if args.mock else get_jev_api_key(), mock=args.mock)
    # One line on stderr so a run log records which decision model was in play.
    # The driver reads stdout only.
    print(
        "decide_server: %s" % ("calibrated simulator" if client.mock else "live TypeSafe Jev"),
        file=sys.stderr,
        flush=True,
    )
    return serve(client, sys.stdin, sys.stdout)


if __name__ == "__main__":
    sys.exit(main())
