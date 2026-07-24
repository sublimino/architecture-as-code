"""The enrichment pipeline internals: EEMS-gated MCP fan-out, correlation,
redaction, and contract-validated payload assembly. The ADK agent in
agent.py orchestrates these; nothing here writes anywhere. The only output
is the enrichment payload the caller publishes (Kafka path) or returns
(A2A path)."""

import asyncio
import hashlib
import json
import logging
import re
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone

import httpx

from . import coin, config, contracts, redact
from .metrics import stage_duration

log = logging.getLogger("olly-sentinel")

ALLOWED_PATTERNS = ["app-logs-*", "infra-logs-*", "audit-logs-*"]


class EemsDenial(Exception):
    pass


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class stage:
    """Context manager timing a pipeline stage into the histogram, labelled by
    the managed app so the tenant dashboards read per-app latency. app_id is
    "unknown" for the consume stage, which runs before the event validates."""

    def __init__(self, name: str, app_id: str = "unknown"):
        self.name = name
        self.app_id = app_id

    def __enter__(self):
        self.start = time.monotonic()
        return self

    def __exit__(self, *exc):
        stage_duration.labels(stage=self.name, app_id=self.app_id).observe(
            time.monotonic() - self.start
        )
        return False


# The tool surface and the scope each one requires. Mirrors the MCP server's
# own scope table; both the client and the server check the scope.
TOOL_SCOPES = {
    "elk_search_logs": "elk.logs.read",
    "grafana_query_metrics": "grafana.dashboards.read",
    "observr_traces": "observr.traces.read",
    "cmdb_lookup_ci": "cmdb.topology.read",
    "io_events_query": "io.events.read",
    "drift_changes": "drift.changes.read",
    "servicenow_inc_chg": "servicenow.incidents.read",
}


_MCP_RPC_ID = 0


async def mcp_call(client: httpx.AsyncClient, tool: str, body: dict) -> dict:
    """One read-only MCP tool call over the MCP JSON-RPC transport
    (tools/call). Entitlement-checked here and again at the server,
    audit-logged on both sides. Raises EemsDenial when the role lacks the
    scope, which removes the tool from the fan-out."""
    global _MCP_RPC_ID
    scope = TOOL_SCOPES.get(tool)
    if scope is None:
        raise EemsDenial(f"unknown tool {tool}")
    if scope not in config.EEMS_SCOPES:
        raise EemsDenial(f"EEMS denial: role {config.EEMS_ROLE} lacks scope {scope}")

    _MCP_RPC_ID += 1
    rpc = {
        "jsonrpc": "2.0",
        "id": _MCP_RPC_ID,
        "method": "tools/call",
        "params": {"name": tool, "arguments": body},
    }
    # COIN M2M: attach the bearer the issuer minted on-behalf-of the human ACME
    # id, via the same headers-provider pattern the client agent.py uses.
    # elk-search-mcp verifies the token and that this tool's scope is in the
    # token's permitted_actions before serving (defence beyond the client check).
    headers = await coin.HEADERS.get_headers()
    resp = await client.post(f"{config.MCP_URL}/mcp", json=rpc, headers=headers, timeout=20.0)
    resp.raise_for_status()
    envelope = resp.json()
    if "error" in envelope:
        raise RuntimeError(f"MCP error for {tool}: {envelope['error']}")
    result = envelope.get("result") or {}
    content = result.get("content") or []
    text = content[0].get("text", "") if content else ""
    out = json.loads(text) if text else {}
    if result.get("isError"):
        raise RuntimeError(f"MCP tool {tool} failed: {str(out)[:200]}")
    log.info(
        'AUDIT {"role":"%s","scope":"%s","tool":"%s","request":%s,"doc_count":%d}',
        config.EEMS_ROLE, scope, tool, json.dumps(body, sort_keys=True),
        int(out.get("doc_count") or out.get("count") or 0),
    )
    return out


async def mcp_search(client: httpx.AsyncClient, pattern: str, query: str) -> dict:
    """Backwards-compatible ELK log search over one index pattern."""
    return await mcp_call(client, "elk_search_logs", {
        "index_pattern": pattern,
        "query": query,
        "size": 50,
        "time_range_minutes": config.QUERY_WINDOW_MINUTES,
    })


@dataclass
class TimelineEntry:
    """One dated observation from one source, ordered into the evidence
    timeline the RCA rests on."""
    at: str
    source: str
    detail: str


@dataclass
class Correlation:
    error_count: int = 0
    total_docs: int = 0
    fault_domain: str = "unknown"
    top_error: str = ""
    sample_lines: list[str] = field(default_factory=list)
    secrets_scrubbed: int = 0
    # Enriched-flow additions. Each is populated from a distinct MCP tool that
    # always runs, so an empty value means that source returned nothing.
    ci: str = ""
    affected_cis: list[str] = field(default_factory=list)
    degraded_upstreams: list[str] = field(default_factory=list)
    timeline: list[TimelineEntry] = field(default_factory=list)
    unapproved_changes: int = 0
    suspected_change: str = ""
    error_spans: int = 0
    sources_queried: list[str] = field(default_factory=list)


# Fault-domain keyword sets, and the priority used to break ties. A specific
# signal (dependency, then infrastructure) beats the generic application bucket.
_DEPENDENCY = ("pool", "timeout", "upstream", "connection")
_INFRASTRUCTURE = ("oom", "restart", "node")
_DATA = ("duplicate", "uniqueness", "stale", "off-by-one", "data quality", "corrupt", "mismatch")
_DOMAIN_PRIORITY = {
    "change": 3,
    "dependency": 2,
    "infrastructure": 1,
    "application": 0,
    "data": 0,
    "unknown": -1,
}

# Deterministic remediation guidance, one list per fault domain. This is
# advice for the SRE; anything executable goes through action-proposal.v1.
# It is computed from the classification, which keeps the model's role to
# narration (design doc §1.2 invariant 8). tests/test_det_vs_llm.py asserts
# the deterministic and narrated runs agree on every field but the summary.
# {app} and {cause} are interpolated per incident.
_ACTIONS: dict[str, list[str]] = {
    "dependency": [
        "confirm the health of the upstream {app} depends on before restarting anything: "
        "a restart clears the symptom and loses the evidence",
        "check pool sizing and acquire timeouts against current demand ({cause})",
        "if the upstream is degraded, fail over or shed load rather than retrying into it",
    ],
    "infrastructure": [
        "check the container's resource limits and recent OOM kills for {app} ({cause})",
        "inspect node conditions (MemoryPressure, DiskPressure) and eviction events for the affected pod",
        "raise the limit or shard the workload; restarting alone will reproduce the fault on the next cycle",
    ],
    "application": [
        "correlate the error burst with the most recent {app} release and roll back if the window matches",
        "guard the failing code path ({cause}) and add a regression test before redeploying",
        "open a defect against the owning team; this is request-handling logic, not infrastructure",
    ],
    "change": [
        "identify the change record in the correlating window and revert it first ({cause})",
        "verify the change was approved and matches the deployed configuration for {app}",
        "if the revert clears the incident, re-land the change behind a flag with a staged rollout",
    ],
    "data": [
        "validate the source extract feeding {app} before touching application code ({cause})",
        "de-duplicate or repair the affected records and re-run the downstream job",
        "add a data-quality assertion at ingest so the same shape fails fast next time",
    ],
    "unknown": [
        "no error-level evidence landed in the queried window for {app}; widen the search window and re-run triage",
        "confirm the app is emitting logs to the expected index before treating this as resolved",
    ],
}


def suggested_actions(c: Correlation, event: dict) -> list[str]:
    """Deterministic, per-incident remediation guidance derived from the fault
    domain the correlation step already resolved. Same inputs, same output."""
    app = event.get("app_id", "the app")
    cause = (c.top_error or "no leading error identified")[:160]
    template = _ACTIONS.get(c.fault_domain, _ACTIONS["unknown"])
    return [line.format(app=app, cause=cause) for line in template]


def _fault_domain(message: str) -> str:
    lower = message.lower()
    if any(w in lower for w in _DEPENDENCY):
        return "dependency"
    if any(w in lower for w in _INFRASTRUCTURE):
        return "infrastructure"
    return "application"


def _is_elk(key: str) -> bool:
    return key.startswith("elk:")


def correlate(results: dict[str, dict]) -> Correlation:
    """Step 6 of the enriched flow: cross-reference every source into one
    fault-domain hypothesis and an evidence timeline.

    All hit text is untrusted data: scrubbed and quoted as data. The fault
    domain is taken from the dominant error signal across all error lines, so a
    single planted or adversarial log entry cannot flip the RCA (threat model:
    an attacker who can write a log line must not steer the agent), and the
    classification is deterministic regardless of hit order.

    Backwards-compatible: the ELK-only offline tests pass {pattern: resp}, so
    any key that is not one of the enriched-flow keys is treated as ELK logs."""
    c = Correlation()
    error_messages: list[str] = []
    errors: list[str] = []
    others: list[str] = []
    enriched_keys = {"grafana", "observr", "drift", "cmdb", "io_events", "servicenow"}

    for key, resp in results.items():
        if not resp:
            continue
        c.sources_queried.append(key)
        # Enriched-flow sources carry structured payloads, handled below.
        if key in enriched_keys:
            _fold_source(c, key, resp)
            continue
        # ELK logs (either "elk:<pattern>" or a bare pattern from the stubs).
        c.total_docs += resp.get("doc_count", 0)
        for hit in resp.get("hits") or []:
            clean, n = redact.scrub(hit.get("message", ""))
            c.secrets_scrubbed += n
            level = hit.get("level", "")
            line = f"[{level} {hit.get('app_id', '')}] {clean}"
            if level == "ERROR":
                c.error_count += 1
                error_messages.append(clean)
                errors.append(line)
                c.timeline.append(TimelineEntry(hit.get("timestamp", ""), "elk", clean[:160]))
            else:
                others.append(line)
    errors.sort()
    c.sample_lines = (errors + others)[:5]
    c.timeline.sort(key=lambda e: e.at)

    if not error_messages:
        c.fault_domain = "unknown"
        c.top_error = ""
        return c

    tally = {"dependency": 0, "infrastructure": 0, "application": 0, "change": 0, "data": 0}
    for message in error_messages:
        tally[_classify(c, message)] += 1

    # A change correlation is a cross-source signal: an error burst that
    # coincides with an unapproved change record is a change-domain fault even
    # though the error text alone reads as application/dependency. Only promote
    # when the change evidence is real (drift found a record).
    if c.suspected_change and c.unapproved_changes > 0 and c.error_count > 0:
        tally["change"] += c.error_count  # the burst is attributed to the change

    c.fault_domain = max(tally, key=lambda d: (tally[d], _DOMAIN_PRIORITY[d]))

    if c.fault_domain == "change" and c.suspected_change:
        c.top_error = c.suspected_change
    else:
        # Probable cause: the first error (sorted for determinism) in the
        # winning domain, so the reported cause matches the classification.
        in_domain = sorted(m for m in error_messages if _classify(c, m) == c.fault_domain)
        c.top_error = in_domain[0] if in_domain else sorted(error_messages)[0]
    return c


def _fold_source(c: Correlation, key: str, resp: dict) -> None:
    """Fold one structured (non-log) source into the correlation. Each branch
    reads only fields the corresponding MCP tool documents; absent data leaves
    the field empty."""
    if key == "cmdb":
        c.ci = resp.get("ci", "")
        for edge in resp.get("edges") or []:
            up = edge.get("upstream", "")
            if edge.get("ci"):
                c.affected_cis.append(edge["ci"])
            if up and not edge.get("up", True):
                c.degraded_upstreams.append(up)
    elif key == "grafana":
        for pt in resp.get("points") or []:
            metric = pt.get("metric", "")
            labels = pt.get("labels") or {}
            val = pt.get("value", 0)
            if metric == "upstream_up" and val == 0 and labels.get("upstream"):
                if labels["upstream"] not in c.degraded_upstreams:
                    c.degraded_upstreams.append(labels["upstream"])
            if metric == "upstream_error_rate_pct" and val >= 10 and labels.get("upstream"):
                c.timeline.append(TimelineEntry(
                    "", "grafana_gem",
                    f"upstream {labels['upstream']} error rate {val:.0f}%"))
    elif key == "observr":
        c.error_spans = int(resp.get("error_spans") or 0)
        for sp in resp.get("spans") or []:
            if sp.get("error") and sp.get("upstream"):
                if sp["upstream"] not in c.degraded_upstreams:
                    c.degraded_upstreams.append(sp["upstream"])
                c.timeline.append(TimelineEntry(
                    sp.get("timestamp", ""), "observr",
                    f"error span {sp.get('service','')} -> {sp['upstream']} ({sp.get('status_code','')})"))
    elif key == "drift":
        c.unapproved_changes = int(resp.get("unapproved_count") or 0)
        for ch in resp.get("changes") or []:
            msg, _ = redact.scrub(ch.get("message", ""))
            ref = ch.get("change_ref", "")
            if ref and not c.suspected_change:
                c.suspected_change = f"{ref}: {msg[:120]}"
            elif not ref and not c.suspected_change:
                c.suspected_change = f"unapproved drift: {msg[:120]}"
            c.timeline.append(TimelineEntry(
                ch.get("timestamp", ""), "drift",
                (f"{ref} " if ref else "unapproved ") + msg[:140]))


def _classify(c: Correlation, message: str) -> str:
    """Fault domain for one error line, using both keyword signal and the
    data-quality bucket the base classifier could not reach."""
    lower = message.lower()
    if any(w in lower for w in _DATA):
        return "data"
    return _fault_domain(message)


async def resolve_context(event: dict) -> dict:
    """Step 4 of the enriched flow: resolve the CI and its topology from the
    CMDB by correlation-ID, before any evidence is gathered. Returns {} when
    the CMDB has nothing for this app, which downstream steps treat as "no
    topology known"."""
    app_id = event["app_id"]
    try:
        async with httpx.AsyncClient() as client:
            return await mcp_call(client, "cmdb_lookup_ci", {"app_id": app_id})
    except EemsDenial:
        raise
    except Exception as exc:  # noqa: BLE001 (CMDB down must not block triage)
        log.warning("cmdb lookup for %s failed: %s", app_id, exc)
        return {}


async def fan_out_all(event: dict) -> tuple[dict[str, dict], list[dict]]:
    """Step 5 of the enriched flow: query every entitled MCP tool in parallel.

    Returns (results-by-key, evidence-entries). A tool that fails or is denied
    is omitted from both, and the omission is logged so an absent source reads
    as "not consulted"."""
    app_id = event["app_id"]
    query = f"app_id:{app_id}"
    window = config.QUERY_WINDOW_MINUTES

    # (result-key, tool, request body, evidence source, evidence query label)
    calls: list[tuple[str, str, dict, str, str]] = [
        (f"elk:{p}", "elk_search_logs",
         {"index_pattern": p, "query": query, "size": 50, "time_range_minutes": window},
         "elk", f"{p} {query}")
        for p in ALLOWED_PATTERNS
    ]
    calls += [
        ("grafana", "grafana_query_metrics", {"app_id": app_id},
         "grafana_gem", f"instant metrics app_id={app_id}"),
        ("observr", "observr_traces", {"app_id": app_id, "time_range_minutes": window},
         "observr", f"traces app_id={app_id}"),
        ("drift", "drift_changes", {"app_id": app_id, "time_range_minutes": window},
         "drift", f"change records app_id={app_id}"),
        ("cmdb", "cmdb_lookup_ci", {"app_id": app_id},
         "cmdb", f"topology app_id={app_id}"),
        ("io_events", "io_events_query", {"app_id": app_id},
         "io_events", f"orchestration decisions app_id={app_id}"),
        ("servicenow", "servicenow_inc_chg", {"app_id": app_id},
         "servicenow_inc", f"tickets app_id={app_id}"),
    ]

    results: dict[str, dict] = {}
    evidence: list[dict] = []
    async with httpx.AsyncClient() as client:
        gathered = await asyncio.gather(
            *(mcp_call(client, tool, body) for _, tool, body, _, _ in calls),
            return_exceptions=True,
        )

    for (key, tool, _body, source, label), res in zip(calls, gathered):
        if isinstance(res, BaseException):
            log.warning("mcp tool %s failed (source omitted from evidence): %s", tool, res)
            continue
        results[key] = res
        evidence.append({
            "source": source,
            "scope": TOOL_SCOPES[tool],
            "query": label,
            "doc_count": int(res.get("doc_count") or res.get("count") or 0),
            "observed_at": _now(),
        })
    if not results:
        raise RuntimeError("all MCP queries failed")
    evidence.sort(key=lambda e: (e["source"], e["query"]))
    return results, evidence


async def fan_out(event: dict) -> tuple[dict[str, dict], list[dict]]:
    """ELK-only fan-out, retained for the offline tests that stub MCP search."""
    app_id = event["app_id"]
    query = f"app_id:{app_id}"
    results: dict[str, dict] = {}
    evidence: list[dict] = []
    async with httpx.AsyncClient() as client:
        gathered = await asyncio.gather(
            *(mcp_search(client, p, query) for p in ALLOWED_PATTERNS),
            return_exceptions=True,
        )
    for pattern, res in zip(ALLOWED_PATTERNS, gathered):
        if isinstance(res, BaseException):
            log.warning("mcp query %s failed: %s", pattern, res)
            continue
        results[pattern] = res
        evidence.append(
            {
                "source": "elk",
                "scope": "elk.logs.read",
                "query": f"{pattern} {query}",
                "doc_count": res.get("doc_count", 0),
                "observed_at": _now(),
            }
        )
    if not results:
        raise RuntimeError("all MCP queries failed")
    evidence.sort(key=lambda e: e["query"])
    return results, evidence


_CHG_RE = re.compile(r"\b(CHG\d{7,10})\b")


def compute_confidence(c: Correlation) -> float:
    """Deterministic confidence computed from evidence strength.

    Starts from the error signal, then adds for each way the finding is
    corroborated: multiple sources consulted, a change that correlates, a
    resolved CI, error spans that agree with the log errors. Capped at 0.95,
    the ceiling for a read-only replica. With no error evidence at all it stays
    low, which trips HITL parking."""
    if c.error_count == 0:
        return 0.3
    score = 0.5
    if len(c.sources_queried) >= 4:
        score += 0.1
    if c.suspected_change and c.unapproved_changes > 0:
        score += 0.15
    if c.ci:
        score += 0.05
    if c.error_spans > 0 and c.degraded_upstreams:
        score += 0.1
    if c.error_count >= 5:
        score += 0.05
    return round(min(score, 0.95), 2)


def assemble(event: dict, c: Correlation, evidence: list[dict],
             summary: str, model_id: str, enrichment_pass: int) -> dict:
    """Step 8 of the enriched flow: build, redact, and contract-validate the
    payload. Raises if the payload drifts from the contract, blocking
    publication of an invalid payload."""
    cause = c.top_error or "no error-level evidence found in the queried window"
    clean_summary, n1 = redact.scrub(summary[:3900])
    clean_cause, n2 = redact.scrub(cause)
    clean_cause = clean_cause[:1900]
    confidence = compute_confidence(c)
    key = hashlib.sha256(
        f"{event['event_id']}|{event['correlation_id']}|{enrichment_pass}".encode()
    ).hexdigest()

    rca: dict = {
        "summary": clean_summary,
        "probable_cause": clean_cause,
        "fault_domain": c.fault_domain,
        "confidence_score": confidence,
        "suggested_actions": suggested_actions(c, event),
    }
    # Enriched-flow fields, only when the source actually produced them.
    if c.affected_cis:
        rca["affected_cis"] = c.affected_cis[:32]
    # suspected_change is pattern-constrained to a bare CHG id; the human-
    # readable detail rides in the timeline instead.
    if c.suspected_change:
        m = _CHG_RE.search(c.suspected_change)
        if m:
            rca["suspected_change"] = m.group(1)
    if c.timeline:
        rca["evidence_timeline"] = [
            {"at": e.at[:40], "source": e.source, "detail": redact.scrub(e.detail)[0][:300]}
            for e in c.timeline[:32]
        ]

    payload = {
        "schema_version": "v1",
        "correlation_id": event["correlation_id"],
        "idempotency_key": key,
        "enrichment_pass": enrichment_pass,
        "agent": {
            "name": "olly-sentinel",
            "version": config.AGENT_VERSION,
            "eval_run_id": config.EVAL_RUN_ID,
            "model_id": model_id,
        },
        "rca": rca,
        "evidence": evidence,
        "redaction": {
            "applied": True,
            "secrets_found": c.secrets_scrubbed + n1 + n2,
        },
    }
    # The resolved CI: prefer what the event carried, else what CMDB resolved.
    ci = event.get("ci") or c.ci
    if ci:
        payload["ci"] = ci[:128]
    contracts.validate(contracts.RCA_ENRICHMENT, payload)
    return payload


def deterministic_summary(event: dict, c: Correlation) -> str:
    cause = c.top_error or "no error-level evidence found in the queried window"
    return (
        f"Deterministic RCA for {event['app_id']} ({event.get('alert_type', '')}): "
        f"{c.error_count} error docs across {c.total_docs} evidence docs. "
        f"Probable cause: {cause}. Evidence sample: {' | '.join(c.sample_lines)}"
    )


def validate_event(raw: bytes) -> dict:
    """Schema-validate an inbound message (the spoofed-event control)."""
    payload = json.loads(raw)
    contracts.validate(contracts.ELIGIBLE_EVENT, payload)
    return payload
