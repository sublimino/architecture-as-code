#!/usr/bin/env python3
"""30-Minute Comprehensive Jev Exploratory QA Fuzzer.

Runs continuous exploratory navigation, deep DOM inspection, and backend API
fuzzing across the Signal Loom platform for a specified duration (default: 30 minutes).
Collects all defects, oracles, HTTP errors, latency metrics, and route coverage,
emitting real-time progress and a final analysis report.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Set

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
sys.path.insert(0, SCRIPT_DIR)

from routes import default_app_tsx, derive_from_file
from bot import JevExploratoryTestBot, BugOracle, PageSnapshot


class ExplorationRunner:
    def __init__(
        self,
        base_url: str,
        duration_seconds: int = 1800,
        out_dir: str = "",
        turns_per_route: int = 6,
        request_delay: float = 0.03,
    ):
        self.base_url = base_url.rstrip("/")
        self.duration_seconds = duration_seconds
        self.turns_per_route = turns_per_route
        self.request_delay = request_delay
        self.start_time = time.monotonic()
        self.end_time = self.start_time + duration_seconds
        self.running = True

        run_id = f"jev-30m-{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}"
        self.out_dir = out_dir or os.path.join(REPO_ROOT, "reports", "jev", run_id)
        os.makedirs(self.out_dir, exist_ok=True)

        self.routes_surface = derive_from_file(default_app_tsx())
        self.api_endpoints: List[str] = []

        # Metrics & Tracking
        self.iterations = 0
        self.total_requests = 0
        self.visited_routes: Set[str] = set()
        self.defects: List[Dict[str, Any]] = []
        self.endpoint_stats: Dict[str, Dict[str, Any]] = {}
        self.latency_samples: List[float] = []
        self.http_status_counts: Dict[int, int] = {}
        self.active_category_counts: Dict[str, int] = {}

        # SSL context (accept self-signed/internal Tailscale certs)
        self.ssl_ctx = ssl.create_default_context()
        self.ssl_ctx.check_hostname = False
        self.ssl_ctx.verify_mode = ssl.CERT_NONE

        signal.signal(signal.SIGINT, self._handle_signal)
        signal.signal(signal.SIGTERM, self._handle_signal)

    def _handle_signal(self, signum, frame):
        print(f"\n[explore-30m] Interrupted by signal {signum}. Finalizing report...", file=sys.stderr)
        self.running = False

    def time_remaining(self) -> float:
        return max(0.0, self.end_time - time.monotonic())

    def elapsed(self) -> float:
        return time.monotonic() - self.start_time

    def log(self, msg: str):
        elapsed_m = int(self.elapsed() // 60)
        elapsed_s = int(self.elapsed() % 60)
        rem_m = int(self.time_remaining() // 60)
        rem_s = int(self.time_remaining() % 60)
        timestamp = time.strftime("%H:%M:%S")
        print(f"\033[90m[{timestamp}]\033[0m \033[36m[{elapsed_m:02d}m{elapsed_s:02d}s elapsed | {rem_m:02d}m{rem_s:02d}s left]\033[0m {msg}", flush=True)

    def discover_apis(self) -> List[str]:
        """Discover API endpoints from the frontend bundle assets."""
        endpoints = set()
        priority_apis = [
            "/api/health",
            "/v1/federation/summary",
            "/v1/federation/events",
            "/v1/telemetry/coding-agents",
            "/health/crypto",
            "/dex/auth",
            "/dex/.well-known/openid-configuration",
            "/api/v1/discovery/workloads",
            "/api/v1/policies",
            "/v1/external-agents/hosts",
            "/afm/clusters",
        ]
        for ep in priority_apis:
            endpoints.add(ep)

        try:
            req = urllib.request.Request(f"{self.base_url}/", headers={"User-Agent": "SignalLoom-JevFuzzer/1.0"})
            with urllib.request.urlopen(req, context=self.ssl_ctx, timeout=8) as resp:
                html = resp.read().decode("utf-8", errors="replace")
            script_srcs = re.findall(r'<script\s+[^>]*src=["\']([^"\']+\.js)["\']', html)
            for src in script_srcs:
                bundle_url = f"{self.base_url}{src}" if src.startswith("/") else src
                try:
                    b_req = urllib.request.Request(bundle_url, headers={"User-Agent": "SignalLoom-JevFuzzer/1.0"})
                    with urllib.request.urlopen(b_req, context=self.ssl_ctx, timeout=10) as b_resp:
                        js_text = b_resp.read().decode("utf-8", errors="replace")
                        found = re.findall(r'"(/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_./-]+)"', js_text)
                        for ep in found:
                            if not any(ep.startswith(p) for p in ["/assets/", "/brand/", "/favicon"]):
                                endpoints.add(ep)
                except Exception:
                    pass
        except Exception as e:
            self.log(f"Warning: Failed to fetch root bundle for API discovery: {e}")

        self.api_endpoints = sorted(list(endpoints))
        return self.api_endpoints

    def http_request(
        self,
        method: str,
        path: str,
        headers: Optional[Dict[str, str]] = None,
        data: Optional[bytes] = None,
        timeout: float = 10.0,
    ) -> Dict[str, Any]:
        """Perform an HTTP request and track metrics."""
        self.total_requests += 1
        url = f"{self.base_url}{path}" if path.startswith("/") else path
        req_headers = {
            "User-Agent": "SignalLoom-JevFuzzer/1.0",
            "Accept": "application/json, text/html, */*",
        }
        if headers:
            req_headers.update(headers)

        req = urllib.request.Request(url, data=data, headers=req_headers, method=method)
        t0 = time.monotonic()
        status_code = 0
        error_msg = ""
        resp_len = 0
        resp_type = ""

        try:
            with urllib.request.urlopen(req, context=self.ssl_ctx, timeout=timeout) as resp:
                status_code = resp.getcode()
                body = resp.read()
                resp_len = len(body)
                resp_type = resp.headers.get("Content-Type", "")
        except urllib.error.HTTPError as e:
            status_code = e.code
            error_msg = e.reason
            try:
                body = e.read()
                resp_len = len(body)
                resp_type = e.headers.get("Content-Type", "")
            except Exception:
                pass
        except urllib.error.URLError as e:
            status_code = 599  # synthetic connection error
            error_msg = str(e.reason)
        except Exception as e:
            status_code = 598
            error_msg = str(e)

        latency = time.monotonic() - t0
        self.latency_samples.append(latency)
        self.http_status_counts[status_code] = self.http_status_counts.get(status_code, 0) + 1

        # Track endpoint stats
        ep_key = path.split("?")[0]
        if ep_key not in self.endpoint_stats:
            self.endpoint_stats[ep_key] = {
                "hits": 0,
                "statuses": {},
                "methods": {},
                "min_latency": latency,
                "max_latency": latency,
                "total_latency": 0.0,
            }
        st = self.endpoint_stats[ep_key]
        st["hits"] += 1
        st["statuses"][status_code] = st["statuses"].get(status_code, 0) + 1
        st["methods"][method] = st["methods"].get(method, 0) + 1
        st["min_latency"] = min(st["min_latency"], latency)
        st["max_latency"] = max(st["max_latency"], latency)
        st["total_latency"] += latency

        # Check for defects
        is_error = False
        cat = ""
        if status_code >= 500:
            is_error = True
            cat = "SERVER_5XX"
        elif status_code == 404 and not any(ep_key.startswith(p) for p in ["/help/connectors/"]):
            # Missing resource / endpoint
            is_error = True
            cat = "NOT_FOUND_404"
        elif status_code == 401:
            cat = "AUTH_REQUIRED_401"
        elif status_code == 403:
            cat = "FORBIDDEN_403"

        if is_error:
            self.defects.append({
                "category": cat,
                "method": method,
                "path": ep_key,
                "url": url,
                "status_code": status_code,
                "error": error_msg,
                "latency_sec": round(latency, 4),
                "timestamp": time.time(),
            })
            self.active_category_counts[cat] = self.active_category_counts.get(cat, 0) + 1

        if self.request_delay > 0:
            time.sleep(self.request_delay)

        return {
            "status_code": status_code,
            "latency": latency,
            "length": resp_len,
            "type": resp_type,
            "error": error_msg,
        }

    def run_exploration_cycle(self):
        """Run one full cycle: UI route fuzzing + API method fuzzing."""
        self.iterations += 1
        self.log(f"━━━ Starting Full Surface Iteration #{self.iterations} ━━━")

        # Part 1: All 46 Frontend Routes via JevBot
        self.log(f"Part 1: Exploring {len(self.routes_surface)} frontend routes (Jev decision turns)...")
        for i, route in enumerate(self.routes_surface, start=1):
            if not self.running or self.time_remaining() <= 0:
                break

            self.visited_routes.add(route)
            # Run bot on this area
            try:
                bot = JevExploratoryTestBot(
                    base_url=self.base_url,
                    area=route,
                    max_turns=self.turns_per_route,
                    timeout=20,
                    mock=True,
                    deep=False,  # We run deep API sweep explicitly in Part 2
                )
                bot_res = bot.run()
                self.total_requests += bot_res.get("turns_executed", 0)
                for err in bot.oracle.errors:
                    cat = err.get("category", "ORACLE_DEFECT")
                    self.defects.append({
                        "category": cat,
                        "method": "NAV",
                        "path": route,
                        "url": err.get("url", route),
                        "status_code": err.get("details", {}).get("status_code", 0),
                        "error": err.get("message", ""),
                        "latency_sec": 0.0,
                        "timestamp": err.get("timestamp", time.time()),
                    })
                    self.active_category_counts[cat] = self.active_category_counts.get(cat, 0) + 1
            except Exception as e:
                self.log(f"Error exploring {route}: {e}")

            if i % 10 == 0 or i == len(self.routes_surface):
                self.log(f"  Front-end progress: {i}/{len(self.routes_surface)} routes walked. Unique defects so far: {len(self.defects)}")

        # Part 2: Backend API Fuzzing (GET, POST, OPTIONS, HEAD)
        if self.running and self.time_remaining() > 0:
            self.log(f"Part 2: Deep API Method Sweep across {len(self.api_endpoints)} discovered endpoints...")
            methods_to_test = ["GET", "POST", "OPTIONS", "HEAD"]

            for ep in self.api_endpoints:
                if not self.running or self.time_remaining() <= 0:
                    break

                for m in methods_to_test:
                    # Provide dummy JSON body for POST
                    data = b'{"probe": "jev-fuzzer"}' if m == "POST" else None
                    hdr = {"Content-Type": "application/json"} if m == "POST" else None
                    self.http_request(m, ep, headers=hdr, data=data)

        self.save_progress()

    def save_progress(self):
        """Save intermediate progress snapshot."""
        p_path = os.path.join(self.out_dir, "progress.json")
        stats = {
            "elapsed_seconds": round(self.elapsed(), 2),
            "time_remaining_seconds": round(self.time_remaining(), 2),
            "iterations_completed": self.iterations,
            "total_requests": self.total_requests,
            "routes_surface_count": len(self.routes_surface),
            "routes_visited_count": len(self.visited_routes),
            "api_endpoints_count": len(self.api_endpoints),
            "defects_count": len(self.defects),
            "status_code_distribution": self.http_status_counts,
            "defect_categories": self.active_category_counts,
            "avg_latency_ms": round(sum(self.latency_samples) / max(1, len(self.latency_samples)) * 1000, 2),
        }
        try:
            with open(p_path, "w", encoding="utf-8") as f:
                json.dump(stats, f, indent=2)
        except Exception:
            pass

    def run(self) -> Dict[str, Any]:
        """Main loop that executes for the duration."""
        self.log(f"════ Jev 30-Minute Exploratory QA Session Initialized ════")
        self.log(f"Target URL:        {self.base_url}")
        self.log(f"Duration Target:   {self.duration_seconds}s ({self.duration_seconds/60:.1f} minutes)")
        self.log(f"Output Directory:  {self.out_dir}")

        self.discover_apis()
        self.log(f"Discovered {len(self.api_endpoints)} backend API routes from frontend bundle.")
        self.log(f"Derived {len(self.routes_surface)} front-end application routes from App.tsx.")

        while self.running and self.time_remaining() > 0:
            self.run_exploration_cycle()

        self.log(f"════ Exploration Window Complete: Generating Final Report ════")
        return self.finalize_report()

    def finalize_report(self) -> Dict[str, Any]:
        """Compile and write comprehensive final report."""
        elapsed = self.elapsed()
        latencies = sorted(self.latency_samples) if self.latency_samples else [0.0]
        p50 = latencies[int(len(latencies) * 0.5)]
        p95 = latencies[int(len(latencies) * 0.95)]
        p99 = latencies[int(len(latencies) * 0.99)]

        # Unique defects by (category, path, status_code)
        unique_defects = {}
        for d in self.defects:
            k = f"{d.get('category')}:{d.get('method')}:{d.get('path')}:{d.get('status_code')}"
            if k not in unique_defects:
                unique_defects[k] = {
                    "category": d.get("category"),
                    "method": d.get("method"),
                    "path": d.get("path"),
                    "status_code": d.get("status_code"),
                    "error": d.get("error"),
                    "occurrences": 0,
                    "first_seen": d.get("timestamp"),
                }
            unique_defects[k]["occurrences"] += 1

        report = {
            "summary": {
                "target_url": self.base_url,
                "duration_seconds": round(elapsed, 2),
                "duration_minutes": round(elapsed / 60, 2),
                "iterations_completed": self.iterations,
                "total_http_requests": self.total_requests,
                "routes_surface_count": len(self.routes_surface),
                "routes_covered_count": len(self.visited_routes),
                "routes_coverage_pct": round(len(self.visited_routes) / max(1, len(self.routes_surface)) * 100, 1),
                "api_endpoints_fuzzed": len(self.api_endpoints),
                "total_defects_observed": len(self.defects),
                "unique_defect_signatures": len(unique_defects),
            },
            "performance": {
                "latency_p50_ms": round(p50 * 1000, 2),
                "latency_p95_ms": round(p95 * 1000, 2),
                "latency_p99_ms": round(p99 * 1000, 2),
                "latency_avg_ms": round(sum(latencies) / max(1, len(latencies)) * 1000, 2),
            },
            "status_distribution": self.http_status_counts,
            "defect_categories": self.active_category_counts,
            "unique_defects": list(unique_defects.values()),
            "endpoint_telemetry": self.endpoint_stats,
            "routes_explored": sorted(list(self.visited_routes)),
        }

        final_path = os.path.join(self.out_dir, "final-report.json")
        with open(final_path, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2)

        self.log(f"Report successfully saved to: {final_path}")
        self.log(f"Total Requests: {self.total_requests} | Iterations: {self.iterations} | Unique Defects: {len(unique_defects)}")
        return report


def main():
    parser = argparse.ArgumentParser(description="30-Minute Jev Exploratory QA Fuzzer")
    parser.add_argument("--url", default="https://ftna-signalloom.taild4da3.ts.net", help="Base target URL")
    parser.add_argument("--duration", type=int, default=1800, help="Total execution duration in seconds (default: 1800)")
    parser.add_argument("--turns", type=int, default=6, help="Max turns per route (default: 6)")
    parser.add_argument("--delay", type=float, default=0.03, help="Inter-request delay in seconds (default: 0.03)")
    parser.add_argument("--out-dir", default="", help="Custom output directory")
    args = parser.parse_args()

    runner = ExplorationRunner(
        base_url=args.url,
        duration_seconds=args.duration,
        out_dir=args.out_dir,
        turns_per_route=args.turns,
        request_delay=args.delay,
    )
    report = runner.run()
    sys.exit(0 if len(report.get("unique_defects", [])) == 0 else 1)


if __name__ == "__main__":
    main()
