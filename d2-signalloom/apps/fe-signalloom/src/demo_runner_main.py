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

from api_compat import install_api_exception_handlers
from demo_runner import install_demo_runner_api

app = FastAPI(title="Signal Loom SuperCred Demo Runner", version="0.1.0")
install_demo_runner_api(app)
install_api_exception_handlers(app)


@app.get("/health")
async def health() -> dict[str, str]:
    """A cheap liveness probe for the standalone demo runner."""
    return {"status": "ok"}


@app.get("/readyz")
async def readyz() -> dict[str, str]:
    """The runner is ready when the process can answer requests."""
    return {"status": "ready"}
