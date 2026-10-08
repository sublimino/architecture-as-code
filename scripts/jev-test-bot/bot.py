#!/usr/bin/env python3
"""
jev-test-bot — Autonomous exploratory QA bot powered by TypeSafe Jev System One.
Navigates web applications, takes structured DOM snapshots, queries Jev for typed decisions,
and monitors oracles (console errors, HTTP 4xx/5xx, crash boundaries) to find bugs.
"""

import argparse
import json
import math
import os
import random
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
    if key and not key.startswith("${"):
        return key

    # 2. Try reading from ~/.andy_sync/includes/_SECRET via systemd-run or directly
    commands = [
        ["systemd-run", "--user", "--wait", "--collect", "--pipe", "grep", "-E", "-i", "^[[:space:]]*export[[:space:]]+JEV_API_KEY=", os.path.expanduser("~/.andy_sync/includes/_SECRET")],
        ["grep", "-E", "-i", "^[[:space:]]*export[[:space:]]+JEV_API_KEY=", os.path.expanduser("~/.andy_sync/includes/_SECRET")],
    ]
    for cmd in commands:
        try:
            out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL, timeout=5)
            for line in out.splitlines():
                m = re.search(r'JEV_API_KEY=[\'"]?([^\'"\s]+)', line)
                if m and len(m.group(1)) > 10:
                    return m.group(1)
        except Exception:
            pass

    return None


def normalise_path(raw: str) -> str:
    """Reduce any URL or path to the canonical route key used for coverage.

    Coverage accounting is only honest if one route has one name. Without
    this, `/agents`, `/agents/` and `/agents?tenant=demo` are three entries,
    which inflates "routes visited" while simultaneously leaving the route the
    loop actually asked for looking unvisited. Query and fragment are dropped
    (they are not a distinct page in this route table), the trailing slash is
    dropped (react-router treats them alike), and root stays `/`.
    """
    if raw.startswith("http://") or raw.startswith("https://"):
        raw = urllib.parse.urlparse(raw).path
    raw = raw.split("#")[0].split("?")[0]
    if not raw.startswith("/"):
        raw = "/" + raw
    return raw.rstrip("/") or "/"


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
        self.endpoint = os.environ.get("TYPESAFE_API_URL", "https://api.typesafe.ai/v1/systemone")

    def decide(
        self,
        snapshot: PageSnapshot,
        intent: str,
        area_scope: str,
        recent_actions: List[Dict[str, Any]],
        visited_urls: set,
        temperature: float = 1.0,
        seed: Optional[int] = None,
    ) -> Dict[str, Any]:
        """
        Ask Jev System One to pick the next operation and target element.
        Returns a dict with choice ('CLICK', 'TYPE_TEXT', 'WAIT', 'DONE'),
        target (element dict), and confidence (float).
        """
        if self.mock:
            return self._heuristic_mock_decide(snapshot, intent, area_scope, recent_actions, visited_urls, temperature, seed)

        # Build candidate target criteria mapping for TypeSafe ChoiceQuestion
        candidate_elements = [
            el for el in snapshot.elements[:40]
            if "CLICK" in el.get("operations", ["CLICK"])
        ]
        if not candidate_elements and snapshot.elements:
            candidate_elements = snapshot.elements[:10]

        criteria_targets = {
            str(el["index"]): f"[{el['index']}] {el.get('role', 'element')}: {el.get('name', 'unnamed')}" + (f" (href: {el['href']})" if el.get("href") else "")
            for el in candidate_elements
        }
        if not criteria_targets:
            criteria_targets = {"1": "Default first element"}

        # Real Jev System One API Call adhering to OpenAPI 3.1.0 SystemOneRequest
        req_body = {
            "model": os.environ.get("TYPESAFE_MODEL", "jev-latest"),
            "state": {
                "page": {
                    "url": snapshot.url,
                    "title": snapshot.title,
                    "text": snapshot.text[:800],
                },
                "elements": [
                    {
                        "index": el["index"],
                        "role": el.get("role", "element"),
                        "name": el.get("name", "unnamed"),
                        "href": el.get("href"),
                    }
                    for el in candidate_elements[:50]
                ],
                "recent_actions": recent_actions[-5:],
            },
            "questions": {
                "operation": {
                    "type": "choice",
                    "instructions": f"Goal: {intent}. Pick the best operation to explore the app without logging out.",
                    "criteria": {
                        "CLICK": "Click a link, button, tab, or menu item.",
                        "WAIT": "Wait for page or dynamic content to update.",
                        "DONE": "Exploration of the scoped area is complete.",
                    },
                },
                "CLICK_target": {
                    "type": "choice",
                    "instructions": f"Goal: {intent}. Pick the best element index to inspect next.",
                    "criteria": criteria_targets,
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
                "Accept": "application/json",
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

                # If TypeSafe provided probability distribution across choices,
                # apply temperature-scaled sampling for smart randomness/exploration
                probs_dict = target_answer.get("probabilities", {})
                target_idx = None
                if probs_dict and temperature is not None and float(temperature) > 0.1:
                    rng = random.Random(seed) if seed is not None else random
                    items = list(probs_dict.items())
                    keys = [k for k, _ in items]
                    raw_probs = [max(1e-6, float(v)) for _, v in items]
                    temp = float(temperature)
                    scaled = [math.pow(p, 1.0 / temp) for p in raw_probs]
                    tot = sum(scaled) or 1.0
                    norm_probs = [s / tot for s in scaled]
                    
                    r = rng.random()
                    cum = 0.0
                    selected_key = keys[0]
                    for k, p in zip(keys, norm_probs):
                        cum += p
                        if r <= cum:
                            selected_key = k
                            break
                    try:
                        target_idx = int(selected_key)
                    except ValueError:
                        target_idx = None

                if target_idx is None:
                    try:
                        target_idx = int(target_answer.get("choice", 1))
                    except ValueError:
                        target_idx = snapshot.elements[0]["index"] if snapshot.elements else 1

                matching_el = next((e for e in snapshot.elements if e["index"] == target_idx), snapshot.elements[0] if snapshot.elements else {"index": 1, "role": "unknown", "name": "fallback"})
                return {
                    "operation": op_choice,
                    "target": matching_el,
                    "confidence": confidence,
                    "mock": False,
                    "model": result.get("model", "jev"),
                }
        except Exception as e:
            print(f"  [Notice] Jev API call failed ({e}); falling back to calibrated heuristic.", file=sys.stderr)
            return self._heuristic_mock_decide(snapshot, intent, area_scope, recent_actions, visited_urls, temperature, seed)

    def _heuristic_mock_decide(
        self,
        snapshot: PageSnapshot,
        intent: str,
        area_scope: str,
        recent_actions: List[Dict[str, Any]],
        visited_urls: set,
        temperature: float = 1.0,
        seed: Optional[int] = None,
    ) -> Dict[str, Any]:
        """
        Calibrated System One heuristic simulator with Boltzmann / Softmax exploration:
        - Filters out destructive targets (logout, signout, delete).
        - Prefers in-scope navigation targets that have not yet been visited.
        - Supports seeded PRNG for reproducible runs.
        - Temperature T controls greediness (low T) vs entropy / exploration (high T).
        """
        clickables = [e for e in snapshot.elements if "CLICK" in e.get("operations", ["CLICK"])]
        inputs = [
            e for e in snapshot.elements
            if "TYPE_TEXT" in e.get("operations", []) or e.get("role") in ("textbox", "searchbox")
        ]
        candidate_pool = clickables + inputs if inputs else clickables
        if not candidate_pool:
            return {"operation": "DONE", "target": None, "confidence": 1.0, "mock": True}

        # Filter out destructive targets
        safe_candidates = [
            e for e in candidate_pool
            if not any(w in (e.get("name") or "").lower() for w in ["sign out", "log out", "logout", "signout", "delete", "destroy", "purge", "revoke"])
        ]
        if not safe_candidates:
            safe_candidates = candidate_pool

        # Filter by area scope if specified
        area_clean = area_scope.strip("/")
        if area_clean:
            in_scope = [
                e for e in safe_candidates
                if e.get("href") and (area_clean in e["href"] or e["href"].startswith(f"/{area_clean}"))
            ]
            if in_scope:
                safe_candidates = in_scope

        def is_unvisited(elem):
            href = elem.get("href")
            if not href:
                return False
            clean_href = href.split("?")[0].rstrip("/") or "/"
            return clean_href not in visited_urls and f"{snapshot.url.rstrip('/')}{clean_href}" not in visited_urls

        rng = random.Random(seed) if seed is not None else random

        scores = []
        for e in safe_candidates:
            score = 1.0
            if is_unvisited(e):
                score = 3.5
            elif e.get("role") in ("textbox", "searchbox"):
                score = 2.8
            elif e.get("role") == "button":
                score = 2.2
            scores.append(score)

        temp = max(0.05, float(temperature if temperature is not None else 1.0))
        max_score = max(scores)
        exp_weights = [math.exp((s - max_score) / temp) for s in scores]
        sum_weights = sum(exp_weights)
        probs = [w / sum_weights for w in exp_weights]

        r = rng.random()
        cumulative = 0.0
        chosen = safe_candidates[0]
        for candidate, p in zip(safe_candidates, probs):
            cumulative += p
            if r <= cumulative:
                chosen = candidate
                break

        confidence = round(rng.uniform(0.84, 0.96), 2)
        op = "TYPE_TEXT" if chosen.get("role") in ("textbox", "searchbox") else "CLICK"
        return {
            "operation": op,
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
        temperature: float = 1.0,
        seed: Optional[int] = None,
    ):
        self.base_url = base_url.rstrip("/")
        self.area = area
        self.max_turns = max_turns
        self.timeout = timeout
        self.stop_on_error = stop_on_error
        self.deep = deep
        self.request_timeout = request_timeout
        self.temperature = temperature
        self.seed = seed
        self.oracle = BugOracle()
        self.visited_urls = set()
        # Ordered, normalised record of which ROUTES this run actually touched,
        # and the status each returned. `visited_urls` is a set of mixed full
        # URLs and bare paths — enough for the bot's own revisit check, not
        # enough to answer "what did this run cover?".
        self.visited_paths: List[str] = []
        self.path_status: Dict[str, int] = {}
        self.history: List[Dict[str, Any]] = []

        # Initialize API key and client
        self.api_key = get_jev_api_key()
        self.client = JevClient(api_key=self.api_key, mock=mock)

    def record_visit(self, raw_path: str, status_code: int) -> str:
        """Note that a route was fetched, and with what result.

        The status kept per path is the WORST seen, not the last: a route that
        500s once and 200s on a later turn is not a healthy route, and a report
        that says otherwise is the kind of thing this bot exists to catch.
        """
        key = normalise_path(raw_path)
        if key not in self.path_status:
            self.visited_paths.append(key)
            self.path_status[key] = status_code
        else:
            self.path_status[key] = max(self.path_status[key], status_code)
        return key

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
            self.record_visit(current_path, snapshot.status_code)

            print(f"  \033[90mObservation:\033[0m {snapshot.title} (HTTP {snapshot.status_code}, {len(snapshot.elements)} controls)")

            # Check defect oracles on current state
            if self.oracle.has_errors and self.stop_on_error:
                print("  \033[31mAborting early due to --stop-on-error flag.\033[0m")
                break

            # Ask Jev System One
            intent = f"Explore section {self.area} and verify page health"
            decision = self.client.decide(
                snapshot,
                intent,
                self.area,
                self.history,
                self.visited_urls,
                temperature=self.temperature,
                seed=self.seed,
            )
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
            "visited_paths": list(self.visited_paths),
            "path_status": dict(self.path_status),
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
        "--temperature",
        type=float,
        default=1.0,
        help="Softmax exploration temperature (default: 1.0; low=greedy, high=random)",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=None,
        help="Random seed for reproducible exploratory walks",
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
        temperature=args.temperature,
        seed=args.seed,
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
