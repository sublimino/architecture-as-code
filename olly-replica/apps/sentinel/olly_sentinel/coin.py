"""COIN M2M token manager for the sentinel.

Mirrors the client agent.py's ``_MCPTokenManager`` / ``_MCPHeadersProvider``:
exchange an on-behalf-of human identity for an M2M-enhanced token at the
in-cluster COIN issuer (olly-authz), cache it, refresh before expiry, and hand
the bearer to the MCP fan-out and the AuthZ-CTX to the Orbit A2A hop. One
``authz_ctx_id`` anchors the whole flow so 'who authorized this?' is a single
audit lookup.

Real by construction: a genuine HTTP token exchange against a running issuer,
carried on real request headers, validated by elk-search-mcp and Orbit. It
fails open on an issuer outage (logs and proceeds unauthenticated, like the
guard and the A2A hand-off) so an authz hiccup never drops an incident, while
the server side still enforces scope when a token is present.
"""

import asyncio
import logging
import time

import httpx

from . import config

log = logging.getLogger("olly-sentinel")


class CoinTokenManager:
    """Holds one cached COIN token, refreshed transparently before it expires."""

    def __init__(self) -> None:
        self._lock = asyncio.Lock()
        self._token = ""
        self._ctx = ""
        self._permitted: list = []
        self._decision = ""
        self._exp = 0.0

    async def _mint(self) -> None:
        payload = {
            "on_behalf_of": config.AUTHZ_ACME_ID,   # OBO: the human ACME id stays the subject
            "agent": config.AUTHZ_AGENT,
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "requested_actions": config.AUTHZ_REQUESTED_ACTIONS,
        }
        async with httpx.AsyncClient(timeout=6.0) as client:
            resp = await client.post(f"{config.COIN_URL}/token", json=payload)
            resp.raise_for_status()
            data = resp.json()
        self._token = data.get("access_token", "")
        self._ctx = data.get("authz_ctx_id", "")
        self._permitted = data.get("permitted_actions", [])
        self._decision = data.get("decision", "")
        self._exp = time.time() + max(30, config.AUTHZ_TOKEN_TTL - 30)
        log.info(
            'AUDIT {"path":"coin","event":"token_minted","authz_ctx_id":"%s",'
            '"acme_id":"%s","decision":"%s","permitted_actions":%d}',
            self._ctx, config.AUTHZ_ACME_ID, self._decision, len(self._permitted),
        )

    async def _ensure(self) -> None:
        if self._token and time.time() < self._exp:
            return
        async with self._lock:
            if self._token and time.time() < self._exp:
                return
            await self._mint()

    async def context(self) -> dict:
        """The current chain context: {token, authz_ctx_id, permitted_actions,
        decision}. Empty token when authz is disabled or the issuer is down."""
        if not config.AUTHZ_ENABLED:
            return {"token": "", "authz_ctx_id": "", "permitted_actions": [], "decision": "disabled"}
        # Static-token escape hatch, mirroring the client's MCP_STATIC_TOKEN: a
        # pre-issued bearer that skips the exchange (no auto-refresh).
        if config.MCP_STATIC_TOKEN:
            return {"token": config.MCP_STATIC_TOKEN, "authz_ctx_id": "static",
                    "permitted_actions": [], "decision": "static"}
        try:
            await self._ensure()
        except Exception as exc:  # noqa: BLE001 - fail open, server still enforces
            log.warning("COIN token mint failed (%s); proceeding unauthenticated", exc)
            return {"token": "", "authz_ctx_id": "", "permitted_actions": [], "decision": "error"}
        return {
            "token": self._token,
            "authz_ctx_id": self._ctx,
            "permitted_actions": self._permitted,
            "decision": self._decision,
        }

    async def mcp_headers(self) -> dict:
        """Authorization header for an MCP tool call (COIN-minted M2M bearer)."""
        ctx = await self.context()
        return {"Authorization": f"Bearer {ctx['token']}"} if ctx["token"] else {}


class MCPHeadersProvider:
    """The Bearer-header provider the MCP fan-out attaches, mirroring the client
    agent.py's ``_MCPHeadersProvider``: it wraps the token manager and returns
    ``{"Authorization": "Bearer <token>"}`` for each call. The client injects
    this into an ADK ``McpToolset`` via an httpx factory; our fan-out is a
    deterministic pipeline, so pipeline.mcp_call attaches the same headers
    directly. Same COIN M2M identity, same header contract."""

    def __init__(self, manager: CoinTokenManager) -> None:
        self._manager = manager

    async def get_headers(self) -> dict:
        return await self._manager.mcp_headers()


# Module-level singletons, like the client's _MCPTokenManager / _MCPHeadersProvider.
MANAGER = CoinTokenManager()
HEADERS = MCPHeadersProvider(MANAGER)
