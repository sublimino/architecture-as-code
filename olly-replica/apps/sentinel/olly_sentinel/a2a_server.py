"""The A2A face of Olly Sentinel, served natively by ADK's ``to_a2a``.

The AgentCard is the immediate proof of value: a deterministic, reviewable
statement of who this agent is, what skills it offers, and what auth it
requires. The committed contract
(contracts/agent-card.olly-sentinel.v1.json) is the single source of truth:
``to_a2a`` loads and serves exactly that file at
``/.well-known/agent-card.json``, and the test suites (pytest here, bats in
the cluster) assert served == committed, so agent identity drift fails CI
exactly like payload contract drift.

The A2A ``message/send`` endpoint is the strategic TROUBLESHOOT action from
the design doc: the same read-only triage pipeline Self-Healing routes to,
invokable directly by an authorized user or peer agent (see the skill
example on the card). It returns the RCA report; it never publishes to
Kafka and never writes to ServiceNow.
"""

import os

from google.adk.a2a.utils.agent_to_a2a import to_a2a

from . import config, contracts
from .agent import SentinelRuntime


def card_path() -> str:
    return os.path.join(config.CONTRACTS_DIR, contracts.AGENT_CARD)


def orbit_card_path() -> str:
    return os.path.join(config.CONTRACTS_DIR, contracts.ORBIT_AGENT_CARD)


def build_a2a_app(runtime: SentinelRuntime):
    """Starlette app: A2A JSON-RPC at ``/`` plus the well-known agent card,
    backed by the same ADK runner the Kafka path uses."""
    return to_a2a(
        runtime.agent,
        agent_card=card_path(),
        runner=runtime.runner,
        port=config.LISTEN_PORT,
    )


def build_orbit_a2a_app():
    """Starlette app for Orbit's own A2A endpoint, or ``None`` when no model is
    configured. Served on its own port so a ``message/send`` invokes the
    approval-gated ``propose_action`` and comes back as an ``input-required``
    task, the native A2A view of the same human approval the Kafka path parks."""
    from google.adk.runners import InMemoryRunner

    from .orbit import APP_NAME, build_orbit_a2a_agent

    agent, _ = build_orbit_a2a_agent()
    if agent is None:
        return None
    runner = InMemoryRunner(agent=agent, app_name=APP_NAME)
    app = to_a2a(
        agent,
        agent_card=orbit_card_path(),
        runner=runner,
        host="0.0.0.0",
        port=config.ORBIT_A2A_PORT,
    )
    # Re-validate the AuthZ-CTX on every inbound A2A message: a valid COIN token
    # that still permits an action after narrowing by Orbit's local grant, or a
    # clean deny. Orbit cannot widen what Olly was granted.
    from starlette.middleware.base import BaseHTTPMiddleware

    from . import authz
    app.add_middleware(BaseHTTPMiddleware, dispatch=authz.orbit_ctx_dispatch)
    return app
