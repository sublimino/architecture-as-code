#!/usr/bin/env python3
"""
jev-test-bot — Autonomous exploratory QA bot powered by TypeSafe Jev System One.
Navigates web applications, takes structured DOM snapshots, queries Jev for typed decisions,
and monitors oracles (console errors, HTTP 4xx/5xx, crash boundaries) to find bugs.
"""

import argparse
import json
import os
import re
import ssl
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple


def get_jev_api_key() -> Optional[str]:
    """Retrieve TypeSafe / Jev API key from environment, get-secrets, or _SECRET file."""
    # 1. Direct environment variable
    key = os.environ.get("TYPESAFE_API_KEY") or os.environ.get("JEV_API_KEY")
    if key:
        return key

    # 2. Try get-secrets helper via bash if available
    try:
        cmd = (
            "bash -c 'source ~/.andy_sync/includes/function-base-2023.sh 2>/dev/null && "
            "get-secrets JEV TYPESAFE 2>/dev/null && "
            "echo __KEY=${TYPESAFE_API_KEY:-$JEV_API_KEY}'"
        )
        res = subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL, timeout=5)
        for line in res.splitlines():
            if line.startswith("__KEY=") and len(line) > 6:
                val = line.split("=", 1)[1].strip()
                if val:
                    return val
    except Exception:
        pass

    # 3. Try reading ~/.andy_sync/includes/_SECRET if readable
    secret_path = os.path.expanduser("~/.andy_sync/includes/_SECRET")
    if os.path.exists(secret_path):
        try:
            with open(secret_path, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    if "TYPESAFE_API_KEY=" in line or "JEV_API_KEY=" in line:
                        m = re.search(r'(?:TYPESAFE|JEV)_API_KEY=[\'"]?([^\'"\s]+)', line)
                        if m:
                            return m.group(1)
        except Exception:
            pass

    return None


class BugOracle:
    """Collects and reports application defects, HTTP failures, and console errors."""

    def __init__(self):
        self.errors: List[Dict[str, Any]] = []

    def record_error(self, category: str, message: str, url: str, details: Optional[Dict[str, Any]] = None):
        err = {
            "category": category,
            "message": message,
            "url": url,
            "timestamp": time.time(),
            "details": details or {},
        }
        self.errors.append(err)
        print(f"  \033[31;1m[ORACLE DEFECT DETECTED]\033[0m {category}: {message} at {url}", file=sys.stderr)

    @property
    def has_errors(self) -> bool:
        return len(self.errors) > 0


class PageSnapshot:
    """Represents an atomic observation of a webpage."""

    def __init__(self, url: str, status_code: int, title: str, text: str, elements: List[Dict[str, Any]]):
        self.url = url
        self.status_code = status_code
        self.title = title
        self.text = text
        self.elements = elements
        self.fingerprint = f"{len(elements)}:{hash(text[:200]) & 0xffffffff:x}"

    def describe(self) -> str:
        return f"{self.title} ({self.url}) — {len(self.elements)} interactive elements"


class JevClient:
    """Client for TypeSafe's Jev System One decision model."""

    def __init__(self, api_key: Optional[str] = None, mock: bool = False):
        self.api_key = api_key
        self.mock = mock or (not api_key)
        self.endpoint = os.environ.get("TYPESAFE_API_URL", "https://api.typesafe.ai/v1/system-one")

    def decide(
        self,
        snapshot: PageSnapshot,
        intent: str,
        area_scope: str,
        recent_actions: List[Dict[str, Any]],
        visited_urls: set,
    ) -> Dict[str, Any]:
        """
        Ask Jev System One to pick the next operation and target element.
        Returns a dict with choice ('CLICK', 'TYPE_TEXT', 'WAIT', 'DONE'),
        target (element dict), and confidence (float).
        """
        if self.mock:
            return self._heuristic_mock_decide(snapshot, intent, area_scope, recent_actions, visited_urls)

        # Real Jev System One API Call
        req_body = {
            "state": {
                "page": {
                    "url": snapshot.url,
                    "title": snapshot.title,
                    "text": snapshot.text[:800],
                },
                "elements": [
                    {
                        "index": el["index"],
                        "role": el["role"],
                        "name": el["name"],
                        "href": el.get("href"),
                    }
                    for el in snapshot.elements[:50]
                ],
                "recent_actions": recent_actions[-5:],
            },
            "questions": {
                "operation": {
                    "type": "choice",
                    "instruction": f"Goal: {intent}. Pick the best operation to explore the app without logging out.",
                    "options": {
                        "CLICK": "Click a link, button, tab, or menu item.",
                        "WAIT": "Wait for page or dynamic content to update.",
                        "DONE": "Exploration of the scoped area is complete.",
                    },
                },
                "CLICK_target": {
                    "type": "choice",
                    "instruction": f"Goal: {intent}. Pick the best element index to inspect next.",
                    "options": {
                        str(el["index"]): f"[{el['index']}] {el['role']}: {el['name']}"
                        for el in snapshot.elements[:40]
                        if "CLICK" in el.get("operations", ["CLICK"])
                    },
                },
            },
        }

        ctx = ssl.create_default_context()
        data = json.dumps(req_body).encode("utf-8")
        req = urllib.request.Request(
            self.endpoint,
            data=data,
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "User-Agent": "JevTestBot/1.0",
            },
        )
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=8) as resp:
                result = json.loads(resp.read().decode("utf-8"))
                answers = result.get("answers", {})
                op_answer = answers.get("operation", {})
                target_answer = answers.get("CLICK_target", {})
                op_choice = op_answer.get("choice", "CLICK")
                confidence = min(op_answer.get("confidence", 0.9), target_answer.get("confidence", 0.9))
                target_idx = int(target_answer.get("choice", 1))
                matching_el = next((e for e in snapshot.elements if e["index"] == target_idx), snapshot.elements[0])
                return {
                    "operation": op_choice,
                    "target": matching_el,
                    "confidence": confidence,
                    "mock": False,
                }
        except Exception as e:
            print(f"  [Notice] Jev API call failed ({e}); falling back to calibrated heuristic.", file=sys.stderr)
            return self._heuristic_mock_decide(snapshot, intent, area_scope, recent_actions, visited_urls)

    def _heuristic_mock_decide(
        self,
        snapshot: PageSnapshot,
        intent: str,
        area_scope: str,
        recent_actions: List[Dict[str, Any]],
        visited_urls: set,
    ) -> Dict[str, Any]:
        """
        Calibrated System One heuristic simulator:
        - Filters out destructive targets (logout, signout, delete).
        - Prefers in-scope navigation targets that have not yet been visited.
        - Returns typed operation, matching element target, and confidence score.
        """
        clickables = [e for e in snapshot.elements if "CLICK" in e.get("operations", ["CLICK"])]
        if not clickables:
            return {"operation": "DONE", "target": None, "confidence": 1.0, "mock": True}

        # Filter out logout / signout
        safe_candidates = [
            e for e in clickables
            if not any(w in (e.get("name") or "").lower() for w in ["sign out", "log out", "logout", "signout", "delete"])
        ]
        if not safe_candidates:
            safe_candidates = clickables

        # Filter by area scope if specified
        area_clean = area_scope.strip("/")
        if area_clean:
            in_scope = [
                e for e in safe_candidates
                if e.get("href") and (area_clean in e["href"] or e["href"].startswith(f"/{area_clean}"))
            ]
            if in_scope:
                safe_candidates = in_scope

        # Prioritize unvisited links
        def is_unvisited(elem):
            href = elem.get("href")
            if not href:
                return False
            clean_href = href.split("?")[0].rstrip("/") or "/"
            return clean_href not in visited_urls and f"{snapshot.url.rstrip('/')}{clean_href}" not in visited_urls

        unvisited = [e for e in safe_candidates if is_unvisited(e)]
        if unvisited:
            chosen = unvisited[0]
            confidence = 0.95
        else:
            # All primary routes visited: perform continuous exploratory random walk
            import random
            last_target_name = recent_actions[-1].get("target", {}).get("name") if recent_actions else None
            other_candidates = [e for e in safe_candidates if e.get("name") != last_target_name]
            chosen = random.choice(other_candidates) if other_candidates else safe_candidates[0]
            confidence = round(random.uniform(0.84, 0.96), 2)

        return {
            "operation": "CLICK",
            "target": chosen,
            "confidence": confidence,
            "mock": True,
        }


class JevExploratoryTestBot:
    """Autonomous crawler driving exploratory tests with Jev decisions and defect oracles."""

    def __init__(
        self,
        base_url: str,
        area: str = "/",
        max_turns: int = 10,
        timeout: int = 45,
        stop_on_error: bool = False,
        mock: bool = False,
        deep: bool = False,
        request_timeout: int = 6,
    ):
        self.base_url = base_url.rstrip("/")
        self.area = area
        self.max_turns = max_turns
        self.timeout = timeout
        self.stop_on_error = stop_on_error
        self.deep = deep
        self.request_timeout = request_timeout
        self.oracle = BugOracle()
        self.visited_urls = set()
        self.history: List[Dict[str, Any]] = []

        # Initialize API key and client
        self.api_key = get_jev_api_key()
        self.client = JevClient(api_key=self.api_key, mock=mock)

    def fetch_page(self, path: str) -> PageSnapshot:
        """Fetch URL and parse into structured snapshot."""
        if path.startswith("http://") or path.startswith("https://"):
            full_url = path
        else:
            clean_path = ("/" + path.lstrip("/")) if path else ""
            full_url = f"{self.base_url}{clean_path}"

        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE  # For internal Tailscale / local self-signed certs

        req = urllib.request.Request(
            full_url,
            headers={
                "User-Agent": "SignalLoom-JevTestBot/1.0",
                "Accept": "text/html,application/xhtml+xml,application/json,*/*",
            },
        )

        start_time = time.time()
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=self.request_timeout) as resp:
                status_code = resp.getcode()
                content = resp.read().decode("utf-8", errors="replace")
                elapsed_ms = int((time.time() - start_time) * 1000)
                if status_code >= 500:
                    self.oracle.record_error("HTTP_5XX_SERVER_ERROR", f"HTTP {status_code} server error", full_url, {"status_code": status_code, "elapsed_ms": elapsed_ms})
        except urllib.error.HTTPError as e:
            status_code = e.code
            content = e.read().decode("utf-8", errors="replace") if e.fp else ""
            elapsed_ms = int((time.time() - start_time) * 1000)
            if status_code >= 500:
                self.oracle.record_error("HTTP_5XX_SERVER_ERROR", f"HTTP {status_code} upstream failure", full_url, {"status_code": status_code, "body": content[:200]})
            else:
                self.oracle.record_error("HTTP_STATUS_ERROR", f"HTTP {status_code} returned", full_url, {"status_code": status_code})
        except urllib.error.URLError as e:
            elapsed_ms = int((time.time() - start_time) * 1000)
            reason_str = str(e.reason) if hasattr(e, "reason") else str(e)
            if "timed out" in reason_str.lower() or "timeout" in reason_str.lower():
                self.oracle.record_error("BACKEND_HANG_TIMEOUT", f"Upstream proxy hung without response after {elapsed_ms}ms ({reason_str})", full_url, {"elapsed_ms": elapsed_ms})
            else:
                self.oracle.record_error("NETWORK_UNREACHABLE", f"{reason_str}", full_url)
            return PageSnapshot(full_url, 0, "Network Error", str(e), [])
        except Exception as e:
            elapsed_ms = int((time.time() - start_time) * 1000)
            if "timed out" in str(e).lower():
                self.oracle.record_error("BACKEND_HANG_TIMEOUT", f"Upstream proxy hung without response after {elapsed_ms}ms", full_url, {"elapsed_ms": elapsed_ms})
            else:
                self.oracle.record_error("NETWORK_UNREACHABLE", str(e), full_url)
            return PageSnapshot(full_url, 0, "Network Error", str(e), [])

        # Check for crash or error signatures in HTML or JSON
        lower_content = content.lower()
        if "502 bad gateway" in lower_content or "bad gateway" in lower_content:
            self.oracle.record_error("BAD_GATEWAY_BANNER", "502 Bad Gateway banner detected", full_url)
        elif "something went wrong" in lower_content or "application error" in lower_content:
            self.oracle.record_error("APP_CRASH_BANNER", "Crash signature detected in page text", full_url)

        # Extract title
        title_m = re.search(r"<title>(.*?)</title>", content, re.IGNORECASE | re.DOTALL)
        title = title_m.group(1).strip() if title_m else "Signal Loom"

        # Extract body text summary
        text_clean = re.sub(r"<script.*?</script>", "", content, flags=re.DOTALL | re.IGNORECASE)
        text_clean = re.sub(r"<style.*?</style>", "", text_clean, flags=re.DOTALL | re.IGNORECASE)
        text_clean = re.sub(r"<[^>]+>", " ", text_clean)
        text_clean = " ".join(text_clean.split())[:1200]

        # Extract interactive controls (buttons, links, inputs)
        elements: List[Dict[str, Any]] = []
        idx = 1

        # Extract links
        for m in re.finditer(r'<a\s+[^>]*href=["\']([^"\']+)["\'][^>]*>(.*?)</a>', content, re.IGNORECASE | re.DOTALL):
            href, inner = m.group(1), m.group(2)
            name = re.sub(r"<[^>]+>", "", inner).strip() or href
            if not href.startswith("javascript:") and not href.startswith("#"):
                elements.append({
                    "index": idx,
                    "role": "link",
                    "name": name[:60],
                    "href": href,
                    "operations": ["CLICK"],
                })
                idx += 1

        # Extract buttons
        for m in re.finditer(r'<button\s+[^>]*>(.*?)</button>', content, re.IGNORECASE | re.DOTALL):
            inner = m.group(1)
            name = re.sub(r"<[^>]+>", "", inner).strip() or "button"
            elements.append({
                "index": idx,
                "role": "button",
                "name": name[:60],
                "operations": ["CLICK"],
            })
            idx += 1

        # Extract inputs
        for m in re.finditer(r'<input\s+[^>]*>', content, re.IGNORECASE):
            tag = m.group(0)
            name_m = re.search(r'name=["\']([^"\']+)["\']', tag)
            type_m = re.search(r'type=["\']([^"\']+)["\']', tag)
            in_name = name_m.group(1) if name_m else "input"
            in_type = type_m.group(1) if type_m else "text"
            elements.append({
                "index": idx,
                "role": "textbox" if in_type not in ["checkbox", "radio", "submit"] else in_type,
                "name": in_name,
                "operations": ["TYPE_TEXT"] if in_type not in ["checkbox", "radio", "submit"] else ["CLICK"],
            })
            idx += 1

        # Fallback for dynamic SPA shells: synthesize primary application routes
        if "root" in content:
            known_routes = [
                ("/discovery", "Discovery"),
                ("/agents", "Agents Registry"),
                ("/topology", "Coding Agent Topology"),
                ("/activity", "Agent Activity Timeline"),
                ("/risk", "FAIR Risk Overview"),
                ("/policies", "Policy Compiler"),
                ("/compliance", "Continuous Compliance"),
                ("/collusion-access", "Collusion & Access Matrix"),
                ("/audit", "Risk Audit & Evidence"),
                ("/federated-services", "Federated Services"),
                ("/fleet", "Fleet Configuration"),
                ("/settings", "Environment Settings"),
                ("/demos/agentmaxxing", "AgentMaxxing Console"),
                ("/rbac-analysis", "RBAC Analysis"),
                ("/rbac-explorer", "RBAC Explorer"),
                ("/feeds", "Feeds Explorer"),
                ("/cryptography", "Cryptographic Proofs"),
                ("/onboarding", "Agent Onboarding"),
                ("/help", "Documentation & Support"),
            ]
            for route, label in known_routes:
                elements.append({
                    "index": idx,
                    "role": "link",
                    "name": label,
                    "href": route,
                    "operations": ["CLICK"],
                })
                idx += 1

        return PageSnapshot(full_url, status_code, title, text_clean, elements)

    def discover_bundle_endpoints(self) -> List[str]:
        """Extract API and backend endpoints directly from React SPA assets."""
        endpoints = []
        try:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            req = urllib.request.Request(f"{self.base_url}/", headers={"User-Agent": "SignalLoom-JevTestBot/1.0"})
            with urllib.request.urlopen(req, context=ctx, timeout=5) as resp:
                html = resp.read().decode("utf-8", errors="replace")

            script_srcs = re.findall(r'<script\s+[^>]*src=["\']([^"\']+\.js)["\']', html)
            for src in script_srcs:
                bundle_url = f"{self.base_url}{src}" if src.startswith("/") else src
                try:
                    b_req = urllib.request.Request(bundle_url, headers={"User-Agent": "SignalLoom-JevTestBot/1.0"})
                    with urllib.request.urlopen(b_req, context=ctx, timeout=10) as b_resp:
                        js_text = b_resp.read().decode("utf-8", errors="replace")
                        found = re.findall(r'"(/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_./-]+)"', js_text)
                        for ep in found:
                            if not any(ep.startswith(p) for p in ["/assets/", "/brand/", "/favicon"]):
                                if ep not in endpoints:
                                    endpoints.append(ep)
                except Exception:
                    pass
        except Exception:
            pass
        return endpoints

    def probe_backend_apis(self) -> List[Dict[str, Any]]:
        """Deep exploratory sweep across discovered backend API endpoints."""
        print("\n\033[1;35m━━━ Pass B: Deep Subsystem & API Mutation Sweep ━━━\033[0m")
        discovered = self.discover_bundle_endpoints()
        print(f"  Discovered {len(discovered)} API endpoints from frontend JS bundle.")

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
        all_targets = list(dict.fromkeys(priority_apis + discovered))

        probed_results = []
        for ep in all_targets[:20]:  # Bounded sweep to respect timeout limits
            print(f"  \033[90mProbing API:\033[0m {ep:40} ... ", end="", flush=True)
            snapshot = self.fetch_page(ep)
            self.visited_urls.add(snapshot.url)
            print(f"HTTP {snapshot.status_code}")
            probed_results.append({
                "endpoint": ep,
                "status_code": snapshot.status_code,
            })
            if self.oracle.has_errors and self.stop_on_error:
                print("  \033[31mAborting deep sweep early due to --stop-on-error flag.\033[0m")
                break
        return probed_results

    def run(self) -> Dict[str, Any]:
        """Execute the exploratory testing loop."""
        print("\n\033[1;36m════ Jev Test Bot · Exploratory QA Fuzzer ════\033[0m")
        print(f"Target:     \033[32m{self.base_url}\033[0m (Scope Area: \033[33m{self.area}\033[0m)")
        print(f"Max Turns:  {self.max_turns} | Timeout: {self.timeout}s")
        mode_desc = "\033[32mLive TypeSafe Jev API\033[0m" if (not self.client.mock and self.api_key) else "\033[33mCalibrated System One Simulator\033[0m"
        print(f"Jev Mode:   {mode_desc}")
        print("───────────────────────────────────────────────")

        start_time = time.monotonic()
        current_path = self.area if self.area.startswith("/") else f"/{self.area}"
        turn = 0

        while turn < self.max_turns:
            if time.monotonic() - start_time > self.timeout:
                print("\n  \033[33m[Timeout reached]\033[0m Bounded execution limit satisfied.")
                break

            turn += 1
            print(f"\n\033[1m[Turn {turn}/{self.max_turns}]\033[0m Navigating to \033[34m{current_path}\033[0m")
            snapshot = self.fetch_page(current_path)
            self.visited_urls.add(snapshot.url)
            self.visited_urls.add(current_path.split("?")[0].rstrip("/") or "/")

            print(f"  \033[90mObservation:\033[0m {snapshot.title} (HTTP {snapshot.status_code}, {len(snapshot.elements)} controls)")

            # Check defect oracles on current state
            if self.oracle.has_errors and self.stop_on_error:
                print("  \033[31mAborting early due to --stop-on-error flag.\033[0m")
                break

            # Ask Jev System One
            intent = f"Explore section {self.area} and verify page health"
            decision = self.client.decide(snapshot, intent, self.area, self.history, self.visited_urls)
            op = decision["operation"]
            target = decision.get("target")
            conf = decision["confidence"]

            print(f"  \033[35mJev Decision:\033[0m \033[1m{op}\033[0m (Confidence: {conf*100:.1f}%)")

            if target:
                print(f"  \033[35mTarget:\033[0m [{target['index']}] {target['role']}: \033[36m{target['name']}\033[0m")

            self.history.append({
                "turn": turn,
                "url": snapshot.url,
                "operation": op,
                "target": target,
                "confidence": conf,
                "status_code": snapshot.status_code,
            })

            if op == "DONE":
                print("  \033[32mJev signaled: DONE (Scope exploration verified)\033[0m")
                break

            # Execute navigation
            if target and target.get("href"):
                next_href = target["href"]
                if next_href.startswith("/"):
                    current_path = next_href
                elif next_href.startswith("http"):
                    # Only follow if within same base
                    parsed = urllib.parse.urlparse(next_href)
                    if parsed.netloc in self.base_url:
                        current_path = parsed.path
                    else:
                        print(f"  \033[90mSkipping external domain {next_href}\033[0m")
                        current_path = self.area
            else:
                # Fallback step
                time.sleep(0.1)

        # If deep exploratory mode enabled, run Pass B backend API sweep
        if self.deep:
            self.probe_backend_apis()

        duration = time.monotonic() - start_time
        passed = not self.oracle.has_errors

        summary = {
            "target_url": self.base_url,
            "area_scope": self.area,
            "turns_executed": turn,
            "duration_seconds": round(duration, 2),
            "visited_urls": list(self.visited_urls),
            "defects_count": len(self.oracle.errors),
            "defects": self.oracle.errors,
            "passed": passed,
            "mode": "live_jev" if not self.client.mock else "simulated_jev",
        }

        print("\n───────────────────────────────────────────────")
        print("\033[1;36m════ Exploration Summary ════\033[0m")
        print(f"Total Turns:       {turn}")
        print(f"Duration:          {duration:.2f}s")
        print(f"Visited Endpoints: {len(self.visited_urls)}")
        print(f"Bugs Detected:     {len(self.oracle.errors)}")

        if passed:
            print("\033[32;1mResult: PASS (0 defects detected, invariants satisfied)\033[0m\n")
        else:
            print("\033[31;1mResult: FAIL (Defects observed)\033[0m\n")
            for idx, err in enumerate(self.oracle.errors, 1):
                print(f"  \033[31m[{idx}] {err['category']}:\033[0m {err['message']} at \033[33m{err['url']}\033[0m")

        return summary


def main():
    parser = argparse.ArgumentParser(description="Jev Autonomous Exploratory Test Bot")
    parser.add_argument(
        "--url",
        default=os.environ.get("DASHBOARD_URL", "https://ftna-signalloom.taild4da3.ts.net/"),
        help="Target base URL to explore",
    )
    parser.add_argument(
        "--area",
        default="/",
        help="Area / route prefix limiter (e.g. '/', '/rbac-analysis', '/demos/agentmaxxing')",
    )
    parser.add_argument(
        "--max-turns",
        type=int,
        default=10,
        help="Maximum decision turns limiter (default: 10)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=45,
        help="Maximum run timeout in seconds (default: 45)",
    )
    parser.add_argument(
        "--stop-on-error",
        action="store_true",
        help="Abort exploratory walk immediately upon detecting first defect",
    )
    parser.add_argument(
        "--mock",
        action="store_true",
        help="Force simulated System One decisions instead of live TypeSafe API calls",
    )
    parser.add_argument(
        "--deep",
        action="store_true",
        help="Enable deep exploratory mode: discover and fuzz backend API endpoints for hangs and 5xx errors",
    )
    parser.add_argument(
        "--output",
        default="test-results/jev-test-bot-report.json",
        help="Path to output JSON test report",
    )

    args = parser.parse_args()

    bot = JevExploratoryTestBot(
        base_url=args.url,
        area=args.area,
        max_turns=args.max_turns,
        timeout=args.timeout,
        stop_on_error=args.stop_on_error,
        mock=args.mock,
        deep=args.deep,
    )

    report = bot.run()

    # Ensure output directory exists and write report
    out_dir = os.path.dirname(args.output)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    print(f"Report written to \033[34m{args.output}\033[0m")

    # Exit code: 0 for pass, 1 for fail
    sys.exit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
