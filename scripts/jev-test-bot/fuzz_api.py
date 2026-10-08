#!/usr/bin/env python3
"""fuzz_api.py — Concurrent stochastic backend API fuzzer with zero-500 invariants.

Tests backend API routes with randomized mutation strategies derived from
`fuzz_payloads.json`: query parameters, JSON bodies, malformed JSON, corrupted
headers, and path variables.

Oracles & Invariants:
  - Valid client rejections (400, 401, 403, 404, 405, 422) are EXPECTED and PASS.
  - Server crashes, unhandled exceptions, and proxy aborts (500, 502, 503, 504)
    are DEFECTS and FAIL the suite.
  - Deterministic replayability via `--seed <N>`.

Usage:
  python3 scripts/jev-test-bot/fuzz_api.py [--url URL] [--seed N] [--requests N] [--concurrency N]
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import random
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))

# ── Payload Loader ─────────────────────────────────────────────────────────

def load_payloads() -> Dict[str, List[str]]:
    candidate = os.path.join(SCRIPT_DIR, "fuzz_payloads.json")
    if os.path.exists(candidate):
        try:
            with open(candidate, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as exc:
            print(f"[Warning] Failed to read fuzz_payloads.json: {exc}", file=sys.stderr)
    return {
        "unicode": ["\u202Ereversed\u202D", "\u0000null_byte", "🔥💥🚀👾"],
        "numbers": ["0", "-1", "NaN", "Infinity", "9007199254740991", "-2147483648"],
        "injection": ["<script>alert(1)</script>", "' OR '1'='1", "{{7*7}}", "${7*7}"],
        "lengths": ["A" * 1000],
        "json_malformed": ['{"unclosed":', "null", "undefined", "{}"],
        "headers": ["Bearer invalid-token-sig", "Bearer \u0000null"],
    }


DEFAULT_ENDPOINTS = [
    "/api/health",
    "/api/me",
    "/v1/me",
    "/health/crypto",
    "/dex/.well-known/openid-configuration",
    "/api/v1/telemetry/coding-agents",
    "/v1/telemetry/coding-agents",
    "/v1/federation/summary",
    "/v1/federation/events",
    "/api/v1/discovery/workloads",
    "/api/v1/policies",
    "/v1/external-agents/hosts",
    "/afm/clusters",
    "/api/v1/evidence",
    "/api/v1/risk/summary",
    "/api/v1/agents",
]


class ApiFuzzer:
    def __init__(
        self,
        base_url: str,
        seed: Optional[int] = None,
        total_requests: int = 120,
        concurrency: int = 8,
        timeout: float = 6.0,
        stop_on_500: bool = False,
        endpoints: Optional[List[str]] = None,
    ):
        self.base_url = base_url.rstrip("/")
        self.seed = seed if seed is not None else int(time.time() * 1000) % 1_000_000
        self.rng = random.Random(self.seed)
        self.total_requests = total_requests
        self.concurrency = concurrency
        self.timeout = timeout
        self.stop_on_500 = stop_on_500

        self.payloads_dict = load_payloads()
        self.all_payloads: List[Tuple[str, str]] = []
        for cat, items in self.payloads_dict.items():
            for item in items:
                self.all_payloads.append((cat, str(item)))

        self.endpoints = endpoints or list(DEFAULT_ENDPOINTS)
        self.ctx = ssl.create_default_context()
        self.ctx.check_hostname = False
        self.ctx.verify_mode = ssl.CERT_NONE

        # Results tracking
        self.results: List[Dict[str, Any]] = []
        self.defects: List[Dict[str, Any]] = []
        self.status_distribution: Dict[int, int] = {}
        self.payload_category_hits: Dict[str, int] = {}
        self.latencies: List[float] = []

    def sample_payload(self) -> Tuple[str, str]:
        if not self.all_payloads:
            return ("fallback", "jev-fuzz")
        return self.rng.choice(self.all_payloads)

    def generate_mutated_request(self) -> Dict[str, Any]:
        endpoint = self.rng.choice(self.endpoints)
        method = self.rng.choice(["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"])
        strategy = self.rng.choice(["query", "body", "headers", "path"])

        cat, payload = self.sample_payload()
        self.payload_category_hits[cat] = self.payload_category_hits.get(cat, 0) + 1

        url = f"{self.base_url}{endpoint}"
        headers: Dict[str, str] = {
            "User-Agent": "JevApiFuzzer/1.0",
            "Accept": "application/json, text/plain, */*",
        }
        body_bytes: Optional[bytes] = None

        if strategy == "query" or method == "GET":
            param_key = self.rng.choice(["q", "limit", "filter", "since", "token", "format", "id", "search"])
            encoded_val = urllib.parse.quote(payload[:200])
            delim = "&" if "?" in url else "?"
            url = f"{url}{delim}{param_key}={encoded_val}"
        elif strategy == "path":
            clean_token = re.sub(r"[/?#\s]", "_", payload[:64])
            url = f"{url.rstrip('/')}/{clean_token}"
        elif strategy == "headers":
            headers["Authorization"] = payload[:256]
            headers["X-Custom-Fuzz"] = payload[:256]
        elif strategy == "body" and method in ("POST", "PUT", "PATCH"):
            body_choice = self.rng.choice(["json_obj", "raw_malformed", "nested"])
            if body_choice == "json_obj":
                headers["Content-Type"] = "application/json"
                body_dict = {
                    "name": payload,
                    "target": payload,
                    "count": self.rng.choice([0, -1, 999999, payload]),
                    "active": self.rng.choice([True, False, None, payload]),
                }
                body_bytes = json.dumps(body_dict).encode("utf-8")
            elif body_choice == "nested":
                headers["Content-Type"] = "application/json"
                body_bytes = json.dumps({"spec": {"parameters": {"payload": payload}}}).encode("utf-8")
            else:
                headers["Content-Type"] = "application/json"
                body_bytes = payload.encode("utf-8", errors="replace")

        return {
            "url": url,
            "method": method,
            "headers": headers,
            "body": body_bytes,
            "strategy": strategy,
            "category": cat,
            "payload_sample": payload[:80],
            "endpoint": endpoint,
        }

    def execute_one(self, req_spec: Dict[str, Any]) -> Dict[str, Any]:
        start = time.monotonic()
        url = req_spec["url"]
        method = req_spec["method"]
        headers = req_spec["headers"]
        body = req_spec["body"]

        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        status_code = 0
        error_msg = ""
        content_preview = ""

        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=self.timeout) as resp:
                status_code = resp.status
                raw = resp.read()
                content_preview = raw.decode("utf-8", errors="replace")[:200]
        except urllib.error.HTTPError as exc:
            status_code = exc.code
            try:
                content_preview = exc.read().decode("utf-8", errors="replace")[:200]
            except Exception:
                pass
        except urllib.error.URLError as exc:
            error_msg = str(exc.reason)
        except Exception as exc:
            error_msg = str(exc)

        elapsed = time.monotonic() - start
        self.latencies.append(elapsed)

        is_5xx = 500 <= status_code < 600
        is_hang = "timed out" in error_msg.lower() or "timeout" in error_msg.lower()

        record = {
            "url": url,
            "endpoint": req_spec["endpoint"],
            "method": method,
            "strategy": req_spec["strategy"],
            "category": req_spec["category"],
            "payload_sample": req_spec["payload_sample"],
            "status_code": status_code,
            "elapsed_ms": round(elapsed * 1000, 2),
            "error": error_msg,
            "body_preview": content_preview,
            "is_defect": is_5xx or is_hang,
        }

        self.status_distribution[status_code] = self.status_distribution.get(status_code, 0) + 1

        if is_5xx:
            self.defects.append({
                "type": "HTTP_5XX_SERVER_ERROR",
                "message": f"{method} {url} returned HTTP {status_code}",
                "status_code": status_code,
                "url": url,
                "strategy": req_spec["strategy"],
                "payload": req_spec["payload_sample"],
                "body_preview": content_preview,
            })
        elif is_hang:
            self.defects.append({
                "type": "BACKEND_HANG_TIMEOUT",
                "message": f"{method} {url} hung and timed out after {round(elapsed*1000)}ms",
                "url": url,
                "strategy": req_spec["strategy"],
                "payload": req_spec["payload_sample"],
            })

        return record

    def run(self) -> Dict[str, Any]:
        print("\n\033[1;36m════ Jev API Stochastic Fuzzer ════\033[0m")
        print(f"Target:        \033[32m{self.base_url}\033[0m")
        print(f"Seed:          \033[33m{self.seed}\033[0m (Mulberry/PRNG deterministic)")
        print(f"Requests:      {self.total_requests} (Concurrency: {self.concurrency})")
        print(f"Endpoints:     {len(self.endpoints)} API targets")
        print(f"Payloads:      {len(self.all_payloads)} variants across {len(self.payloads_dict)} categories")
        print("───────────────────────────────────────────────")

        req_specs = [self.generate_mutated_request() for _ in range(self.total_requests)]
        started = time.monotonic()

        with concurrent.futures.ThreadPoolExecutor(max_workers=self.concurrency) as pool:
            futures = [pool.submit(self.execute_one, spec) for spec in req_specs]
            done_count = 0
            for future in concurrent.futures.as_completed(futures):
                done_count += 1
                rec = future.result()
                self.results.append(rec)
                status_color = "\033[32m" if 200 <= rec["status_code"] < 300 else "\033[33m" if 400 <= rec["status_code"] < 500 else "\033[31m"
                print(
                    f" [{done_count:03d}/{self.total_requests:03d}] {rec['method']:6} {rec['endpoint'][:30]:30} "
                    f"→ {status_color}HTTP {rec['status_code']}\033[0m ({rec['elapsed_ms']}ms) "
                    f"[{rec['category']}]"
                )
                if self.stop_on_500 and rec["is_defect"]:
                    print("\n\033[31mAborting early: 5xx defect observed and --stop-on-500 enabled.\033[0m")
                    pool.shutdown(wait=False, cancel_futures=True)
                    break

        total_elapsed = time.monotonic() - started
        sorted_latencies = sorted(self.latencies) if self.latencies else [0.0]
        p50 = sorted_latencies[int(len(sorted_latencies) * 0.50)] * 1000
        p95 = sorted_latencies[int(len(sorted_latencies) * 0.95)] * 1000
        rps = round(len(self.results) / max(0.01, total_elapsed), 1)

        print("\n\033[1m━━━ Fuzzing Summary ━━━\033[0m")
        print(f"Total Requests: {len(self.results)} in {total_elapsed:.2f}s ({rps} req/sec)")
        print(f"Latencies:     p50={p50:.1f}ms, p95={p95:.1f}ms, max={max(sorted_latencies)*1000:.1f}ms")
        print(f"Status Codes:  {dict(sorted(self.status_distribution.items()))}")
        print(f"Categories:    {self.payload_category_hits}")
        print(f"Defects Found: {len(self.defects)}")

        passed = len(self.defects) == 0
        if passed:
            print("\033[32;1mResult: PASS (0 server errors, all invariants preserved under adversarial fuzzing)\033[0m\n")
        else:
            print("\033[31;1mResult: FAIL (Server 5xx or hang defects detected)\033[0m\n")
            for idx, d in enumerate(self.defects, 1):
                print(f"  \033[31m[{idx}] {d['type']}:\033[0m {d['message']} [payload: {d['payload']}]")

        return {
            "target": self.base_url,
            "seed": self.seed,
            "total_requests": len(self.results),
            "duration_seconds": round(total_elapsed, 2),
            "requests_per_sec": rps,
            "latencies_ms": {
                "p50": round(p50, 2),
                "p95": round(p95, 2),
                "max": round(max(sorted_latencies) * 1000, 2),
            },
            "status_distribution": self.status_distribution,
            "category_hits": self.payload_category_hits,
            "defects_count": len(self.defects),
            "defects": self.defects,
            "passed": passed,
        }


def main():
    parser = argparse.ArgumentParser(description="Jev Stochastic Backend API Fuzzer")
    parser.add_argument(
        "--url",
        default=os.environ.get("DASHBOARD_URL", "https://ftna-signalloom.taild4da3.ts.net/"),
        help="Target base URL",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=None,
        help="Random seed for reproducible PRNG mutation sequences",
    )
    parser.add_argument(
        "--requests",
        type=int,
        default=100,
        help="Total mutated requests to execute (default: 100)",
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=8,
        help="Concurrent request threads (default: 8)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=6.0,
        help="Per-request timeout in seconds (default: 6.0)",
    )
    parser.add_argument(
        "--stop-on-500",
        action="store_true",
        help="Abort immediately upon first HTTP 5xx or server crash",
    )
    parser.add_argument(
        "--output",
        default="reports/jev/api-fuzz-report.json",
        help="Path to output JSON summary report",
    )

    args = parser.parse_args()

    fuzzer = ApiFuzzer(
        base_url=args.url,
        seed=args.seed,
        total_requests=args.requests,
        concurrency=args.concurrency,
        timeout=args.timeout,
        stop_on_500=args.stop_on_500,
    )

    report = fuzzer.run()

    out_file = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(out_file), exist_ok=True)
    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    print(f"Report written to \033[34m{out_file}\033[0m")

    sys.exit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
