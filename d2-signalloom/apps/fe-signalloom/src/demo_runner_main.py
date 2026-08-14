"""Serve only the SuperCred demo runner in its own workload.

This module exists so the dedicated in-cluster demo-runner pod can expose the
fixed SuperCred orchestration surface without inheriting the Discovery Portal's
broader business API or database lifecycle. The threat model is accidental
privilege expansion: the runner must share the authenticated error envelope and
router behavior needed by ``demo_runner``, but it must not initialise the
PostgreSQL pool or publish unrelated compatibility routes.
"""
from __future__ import annotations

from fastapi import FastAPI
from fastapi.responses import JSONResponse

from api_compat import install_api_exception_handlers
from demo_runner import _ENV_AUDIT_SINK, _audit_sink_url, install_demo_runner_api

app = FastAPI(title="Signal Loom SuperCred Demo Runner", version="0.1.0")
install_demo_runner_api(app)
install_api_exception_handlers(app)


@app.get("/health")
async def health() -> dict[str, str]:
    """A cheap liveness probe for the standalone demo runner."""
    return {"status": "ok"}


@app.get("/readyz")
async def readyz() -> JSONResponse:
    """Ready when the process can answer requests AND record what it is asked to do.

    The second half is new, and it is the only place this condition is
    visible. This workload deliberately owns no database, so the audit rows for
    the privileged phases it drives are forwarded to fe-signalloom over HTTP.
    With no sink configured they fall back to a per-process dict that dies with
    the pod -- silently, because the runs themselves still succeed and answer
    202. No request can tell you it happened; the rows are simply not there
    afterwards, which is exactly the failure the server-side audit trail
    replaced.

    Made a readiness condition rather than a startup crash so the distinction
    survives in the cluster: liveness still passes, so the pod is not
    restart-looped into a CrashLoopBackOff that hides the reason. It just never
    joins its Service, the rollout stalls, and `kubectl describe` names the
    probe. A runner that cannot record a privileged invocation does not get to
    receive one.
    """
    if not _audit_sink_url():
        return JSONResponse(
            status_code=503,
            content={
                "status": "not_ready",
                "reason": (
                    f"{_ENV_AUDIT_SINK} is not set, so privileged invocations would be "
                    "recorded only in memory and lost with this pod"
                ),
            },
        )
    return JSONResponse(content={"status": "ready"})
