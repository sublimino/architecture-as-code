"""Lifecycle metrics: the Eye in the Sky instrumentation contract. Names and
labels are referenced verbatim by the dashboard's PromQL, so any change must
be made in both places."""

from prometheus_client import Counter, Gauge, Histogram

# app_id labels the per-incident metrics so the tenant dashboards slice by
# managed app. It is "unknown" for spoofed events (rejected before an app_id
# is known) and the pre-validation consume stage.
#
# `path` distinguishes the two entry points that reach the same pipeline:
# "kafka" (the Self-Healing declined path) and "a2a" (the direct TROUBLESHOOT
# skill), so A2A traffic is visible to these counters.
#
# `app_id` on hitl_pending lets the per-app escalation cell read a per-app
# queue depth. Every dashboard query wraps these in sum(), so these labels
# aggregate away under existing PromQL.
received = Counter(
    "olly_incidents_received",
    "Events consumed from the queue and declined topics.",
    ["app_id", "path"],
)
processed = Counter(
    "olly_incidents_processed", "Events by terminal outcome.", ["outcome", "app_id", "path"]
)
hitl_pending = Gauge(
    "olly_hitl_pending", "Enrichments parked for human approval.", ["approver", "app_id"]
)
hitl_decisions = Counter(
    "olly_hitl_decisions",
    "Parked enrichments resolved by a human, by decision.",
    ["decision", "app_id"],
)
narrator_fallback = Counter(
    "olly_narrator_fallback",
    "Enrichments that fell back to the deterministic summary because the "
    "LLM narrator failed. A silent climb here means the RCA text is no "
    "longer model-written even though a model is configured.",
    ["app_id"],
)
stage_duration = Histogram(
    "olly_stage_duration_seconds",
    "Per-stage pipeline latency.",
    ["stage", "app_id"],
    buckets=[0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60],
)
llm_tokens = Counter(
    "olly_llm_tokens", "Tokens consumed via the LLM gateway shim.", ["app_id"]
)

# Initialise the HITL gauge so the control-tower pane reads 0 while empty; an
# unseeded gauge renders as NO DATA. One child per managed app gives the
# per-app escalation cell a series to read before the first parked enrichment
# exists.
for _app in ("inventory-service", "payments-api", "customer-portal"):
    hitl_pending.labels(approver="sre-oncall", app_id=_app).set(0)
# Touch the "unknown" children so olly_incidents_received_total and
# olly_incidents_processed_total are exposed before the first event arrives.
# Both paths are touched: consumer-group offsets survive a pod restart, so
# without this a restarted sentinel that replays nothing exposes an empty
# counter family and every panel built on it reads NO DATA.
for _path in ("kafka", "a2a"):
    received.labels(app_id="unknown", path=_path)
    processed.labels(outcome="completed", app_id="unknown", path=_path)
