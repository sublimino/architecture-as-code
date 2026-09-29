"""Discovery Portal API health surface for the D2 demo."""
from __future__ import annotations

import logging
from contextlib import asynccontextmanager

logger = logging.getLogger(__name__)

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from adapters import load_adapter_selections
from api_compat import install_compatibility_api
from audit_ingest import install_audit_ingest_api
from coding_agent_telemetry import install_coding_agent_telemetry_api
from demo_runner import install_demo_runner_api
from environment_lifecycle import GLOBAL_REAPER_DAEMON, install_environment_lifecycle_api
from environment_routing import install_environment_routing_api
from onboarding import install_onboarding_api
from rbac_correlation import install_rbac_api
from risk import install_risk_api
from routers.connectors import install_connectors_api
from routers.discovery import install_discovery_api
from routers.agents import install_agents_api
from routers.policy_engine import install_policy_engine_api
from scenario_seeding import install_scenario_seeding_api
from signal_fusion import install_signal_fusion_api
from tenant_isolation import install_tenant_isolation_api
from db.connection import close_db_pool, get_pool, init_db_pool


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db_pool()
    app.state.adapters = load_adapter_selections()
    GLOBAL_REAPER_DAEMON.start()
    try:
        yield
    finally:
        await GLOBAL_REAPER_DAEMON.stop()
        await close_db_pool()


app = FastAPI(title="Signal Loom Discovery Portal", version="0.1.0", lifespan=lifespan)


# EAPR-P2-1 credential doctrine (decided 2026-09-23): no identity is ever read
# from a request header.  Tenancy comes from the verified principal only, so
# any inbound identity header is dropped at ingress before routing.  Pure ASGI
# (not BaseHTTPMiddleware) so websocket scopes are covered as well as http.
# Header names are matched lower-case, as the ASGI spec guarantees they arrive.
STRIPPED_IDENTITY_HEADERS: frozenset[bytes] = frozenset({b"x-forwarded-user", b"x-tenant-id"})
STRIPPED_IDENTITY_HEADER_PREFIXES: tuple[bytes, ...] = (b"x-spiffe", b"x-tenant", b"x-principal")


def _is_identity_header(name: bytes) -> bool:
    # ``X_Tenant_Id`` is the same claim as ``X-Tenant-Id`` to anything that
    # normalises names (CGI-style servers, some proxies); strip both spellings.
    name = name.replace(b"_", b"-")
    return name in STRIPPED_IDENTITY_HEADERS or name.startswith(STRIPPED_IDENTITY_HEADER_PREFIXES)


class IdentityHeaderStripMiddleware:
    """Remove client-asserted identity headers from ``scope["headers"]`` before routing."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] in ("http", "websocket"):
            headers = scope.get("headers") or []
            kept = [(name, value) for name, value in headers if not _is_identity_header(name.lower())]
            if len(kept) != len(headers):
                scope = dict(scope)
                scope["headers"] = kept
        await self.app(scope, receive, send)


install_compatibility_api(app)
install_onboarding_api(app)
install_audit_ingest_api(app)
install_rbac_api(app)
install_demo_runner_api(app)
install_signal_fusion_api(app)
install_coding_agent_telemetry_api(app)
install_risk_api(app)
install_policy_engine_api(app)
install_connectors_api(app)
install_discovery_api(app)
install_agents_api(app)
install_environment_routing_api(app)
install_tenant_isolation_api(app)
install_environment_lifecycle_api(app)
install_scenario_seeding_api(app)
# Added last so it is the OUTERMOST middleware (Starlette wraps later additions
# around earlier ones): identity headers are gone before any other middleware,
# dependency or handler can read them, for http and websocket scopes alike.
app.add_middleware(IdentityHeaderStripMiddleware)


@app.get("/health")
async def health() -> dict[str, str]:
    """Existing backwards-compatible health endpoint."""
    return {"status": "ok"}


@app.get("/livez")
async def livez() -> dict[str, str]:
    """A process/event-loop probe; it intentionally touches no dependencies."""
    return {"status": "live"}


@app.get("/readyz")
async def readyz(request: Request) -> JSONResponse:
    """PostgreSQL gates readiness; Redis availability is diagnostic only."""
    try:
        await get_pool().fetchval("SELECT 1")
    except Exception:
        logger.exception("discovery portal: PostgreSQL readiness check failed")
        return JSONResponse(status_code=503, content={"status": "not-ready", "postgresql": "unavailable", "redis": "unknown"})

    redis_state = "disabled"
    redis = getattr(request.app.state, "redis", None)
    if redis is not None:
        try:
            await redis.ping()
            redis_state = "ready"
        except Exception:
            logger.warning("discovery portal: Redis degraded", exc_info=True)
            redis_state = "degraded"
    return JSONResponse(content={"status": "ready", "postgresql": "ready", "redis": redis_state})
