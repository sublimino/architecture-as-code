"""Orbit: the action agent behind Olly's strategic decision.

The enrichment flow ends, in Phase 1, at "currently no actions will be taken".
Orbit is the component that fills that node: given a completed RCA it proposes
exactly one action from a closed enum (``action-proposal.v1``), a human approves
it with a signed token, and a deterministic executor records the action under a
separate identity. Orbit proposes; approval and the execution credential belong
to separate identities (design-doc invariant 6).

Orbit is an ADK ``LlmAgent`` when a model is configured: it reasons over the RCA
and selects the action, and its choice is validated against the closed enum, so
a model that returns anything off-enum falls back to ``no_action``. Without a
model it uses a deterministic mapping from the fault domain. Either way the
action is one enum value, the human approval gate is unchanged, and the executor
is deterministic.

Two entry points, one proposal machinery:

  * **Kafka path**: an enrichment that warrants an action is parked as a
    proposal, held in the store until approved from the console.
  * **A2A path**: a direct authorized request (the diagram's "or directly via
    an authorized user request") invokes the ``propose_action`` skill, exposed
    as an ADK ``FunctionTool`` with ``require_confirmation=True`` so ADK's native
    HITL turns it into an A2A ``input-required`` task.
"""

import hashlib
import json
import logging
from typing import Optional

from . import config, contracts

log = logging.getLogger("olly-sentinel")

APP_NAME = "olly-orbit"

# The closed action enum, from action-proposal.v1. Growing this list is a
# governance decision.
ACTION_TROUBLESHOOT = "troubleshoot"
ACTION_REMEDIATE_RESTART = "remediate_restart_service"
ACTION_NO_ACTION = "no_action"
ACTIONS = {ACTION_TROUBLESHOOT, ACTION_REMEDIATE_RESTART, ACTION_NO_ACTION}

# The action-proposal vocabulary maps onto the AuthZ entitlement vocabulary the
# COIN token and Orbit's local grant use: proposing a restart requires the
# restart_service entitlement, troubleshoot is the same word in both, and
# no_action delegates nothing. a2a_engage sends the mapped name as X-AuthZ-Action
# so Orbit checks the entitlement it actually holds, not the proposal verb.
AUTHZ_ACTION = {
    ACTION_TROUBLESHOOT: "troubleshoot",
    ACTION_REMEDIATE_RESTART: "restart_service",
    ACTION_NO_ACTION: "",
}

ORBIT_INSTRUCTION = (
    "You are Orbit, an SRE action agent for a financial-services platform "
    "(ledgers, payment settlement, the customer banking portal). Given a "
    "completed root-cause analysis, choose the single most appropriate next "
    "action from this closed set, and ONLY this set:\n"
    "  troubleshoot: a deeper read-only investigation; safe, no mutation.\n"
    "  remediate_restart_service: restart the affected service. Choose this "
    "ONLY for an infrastructure fault whose evidence is a crash, OOM, or "
    "restart loop that a restart actually clears.\n"
    "  no_action: nothing is warranted right now.\n"
    "You PROPOSE only. A human approves and a separate deterministic system "
    "executes under a different identity, so never assume the action runs. "
    "Respond with a single-line JSON object and nothing else:\n"
    '{{"action": "<one of troubleshoot|remediate_restart_service|no_action>", '
    '"justification": "<=280 chars, name the impacted service and why"}}\n'
    "RCA for app {app_id} (fault domain {fault_domain}):\n"
    "summary: {rca_summary}\n"
    "probable cause: {probable_cause}"
)


def _build_payload(enrichment: dict, action: str, justification: str, app_id: str = "") -> dict:
    """Assemble and contract-validate an action-proposal.v1 payload. The
    mutating action is bounded to infrastructure faults regardless of the
    model's choice: a restart is only ever proposed for the fault shape a
    restart addresses."""
    if action not in ACTIONS:
        action = ACTION_NO_ACTION
    if action == ACTION_REMEDIATE_RESTART:
        domain = enrichment.get("rca", {}).get("fault_domain", "")
        if domain != "infrastructure":
            action = ACTION_TROUBLESHOOT
    correlation_id = enrichment.get("correlation_id", "")
    app_id = _app_from(enrichment, app_id)
    proposal_id = "prop-" + hashlib.sha256(
        f"{correlation_id}|{action}|{enrichment.get('idempotency_key', '')}".encode()
    ).hexdigest()[:24]
    evidence_refs = [
        f"{e.get('source')}:{e.get('query')}"[:256]
        for e in (enrichment.get("evidence") or [])[:8]
    ]
    payload = {
        "schema_version": "v1",
        "proposal_id": proposal_id,
        "correlation_id": correlation_id,
        "app_id": app_id,
        "action": action,
        "justification": (justification or "no justification given")[:2000],
        "evidence_refs": evidence_refs,
        "approval": {"state": "proposed"},
    }
    contracts.validate(contracts.ACTION_PROPOSAL, payload)
    return payload


def propose(enrichment: dict, app_id: str = "") -> dict:
    """Deterministic action selection from the fault domain. Used as the
    fallback when no model is configured, and directly by the unit tests.

    A restart is proposed only for an infrastructure fault whose evidence is a
    crash/OOM/restart loop, the one shape a service restart addresses.
    Everything else proposes troubleshoot (a read-only deep dive) or
    no_action."""
    rca = enrichment.get("rca", {})
    domain = rca.get("fault_domain", "unknown")
    cause = (rca.get("probable_cause") or "").lower()
    app_id = _app_from(enrichment, app_id)

    restart_shaped = any(w in cause for w in ("oom", "restart", "crash", "killed", "evicted"))
    if domain == "infrastructure" and restart_shaped:
        action = ACTION_REMEDIATE_RESTART
        justification = (
            f"Infrastructure fault on {app_id} with a crash/OOM signature "
            f"({rca.get('probable_cause', '')[:200]}). A controlled restart of the "
            f"affected service is the candidate remediation; requires approval."
        )
    elif domain in ("dependency", "application", "change", "data"):
        action = ACTION_TROUBLESHOOT
        justification = (
            f"{domain.capitalize()} fault on {app_id}: propose a deeper read-only "
            f"troubleshoot to widen evidence and confirm the upstream or change "
            f"before any remediation."
        )
    else:
        action = ACTION_NO_ACTION
        justification = f"No confident, restart-addressable fault on {app_id}; Phase 1 default."
    return _build_payload(enrichment, action, justification)


class OrbitRuntime:
    """Runs the Orbit LlmAgent to select an action, with the deterministic
    mapping as the fallback. The agent proposes; the enum is enforced here."""

    def __init__(self) -> None:
        self.agent = _make_orbit_agent()
        self.runner = None
        if self.agent is not None:
            from google.adk.runners import InMemoryRunner
            self.runner = InMemoryRunner(agent=self.agent, app_name=APP_NAME)

    async def propose(self, enrichment: dict, app_id: str = "") -> dict:
        if self.runner is None:
            return propose(enrichment, app_id)
        rca = enrichment.get("rca", {})
        from google.genai import types
        session_id = enrichment.get("correlation_id", "orbit") + "-orbit"
        await self.runner.session_service.create_session(
            app_name=APP_NAME, user_id="orbit", session_id=session_id,
            state={
                "app_id": _app_from(enrichment, app_id),
                "fault_domain": rca.get("fault_domain", "unknown"),
                "rca_summary": (rca.get("summary") or "")[:1200],
                "probable_cause": (rca.get("probable_cause") or "")[:600],
            },
        )
        message = types.Content(role="user", parts=[types.Part(text="Propose the next action.")])
        text = ""
        try:
            async for ev in self.runner.run_async(user_id="orbit", session_id=session_id, new_message=message):
                if ev.is_final_response() and ev.content and ev.content.parts:
                    text = ev.content.parts[0].text or ""
        except Exception as exc:  # noqa: BLE001 - a model failure falls back
            log.warning("orbit LLM failed, using deterministic proposal: %s", exc)
            return propose(enrichment, app_id)
        action, justification = _parse_action(text)
        if action not in ACTIONS:
            log.info("orbit LLM returned off-enum action %r; deterministic fallback", action)
            return propose(enrichment, app_id)
        return _build_payload(enrichment, action, justification, app_id)


def _make_orbit_agent():
    """Build the Orbit LlmAgent, or None when no model is configured."""
    from . import agent as agent_mod
    from google.adk.agents import LlmAgent

    model, model_id = agent_mod.build_model()
    if model is None:
        return None
    log.info("orbit LLM agent active: model=%s", model_id)
    return LlmAgent(
        name="orbit_action_agent",
        model=model,
        description="Proposes one action-proposal.v1 action from the closed enum; never acts.",
        instruction=ORBIT_INSTRUCTION,
    )


def _parse_action(text: str) -> tuple[str, str]:
    """Pull {action, justification} out of the model's reply, tolerating stray
    prose or code fences around the JSON."""
    s = (text or "").strip()
    start, end = s.find("{"), s.rfind("}")
    if start >= 0 and end > start:
        try:
            obj = json.loads(s[start:end + 1])
            return str(obj.get("action", "")).strip(), str(obj.get("justification", "")).strip()
        except Exception:  # noqa: BLE001
            pass
    for a in ACTIONS:
        if a in s:
            return a, "parsed from unstructured reply"
    return "", ""


def _app_from(enrichment: dict, app_id: str = "") -> str:
    """Resolve a schema-valid app_id for the proposal. The enrichment is keyed
    by correlation-ID and does not carry app_id, so the caller passes it in;
    the enrichment's own app_id is used only as a fallback in the unit tests."""
    return app_id or enrichment.get("app_id") or "unknown-app"


def handoff_message(correlation_id: str, action: str, enrichment: dict) -> str:
    """The message Olly sends to Orbit over A2A. It carries the RCA context Orbit
    needs to reason about the action, which is also the content an attacker's
    planted log text would ride across on, so this is the exact string the LLM
    Guard input scanners screen before Orbit sees it. The redactor has already
    scrubbed secrets/PII from these fields; the guard is the second opinion that
    catches an injection or a model-detected identifier the regex missed."""
    rca = enrichment.get("rca", {}) if isinstance(enrichment, dict) else {}
    summary = (rca.get("summary") or "")[:600]
    cause = (rca.get("probable_cause") or "")[:300]
    return (
        f"Propose the next action for correlation_id {correlation_id}. "
        f"Fault domain: {rca.get('fault_domain', 'unknown')}. "
        f"Olly's read of the fault points to {action}. "
        f"Probable cause: {cause} RCA summary: {summary}"
    ).strip()


def _extract_reply_text(result: dict) -> str:
    """Pull any human-readable text out of Orbit's A2A task reply (status message
    or artifacts), best-effort, so the output scanners have something to screen."""
    chunks: list[str] = []
    status_msg = (result.get("status") or {}).get("message") or {}
    for part in status_msg.get("parts") or []:
        if isinstance(part, dict) and part.get("text"):
            chunks.append(str(part["text"]))
    for artifact in result.get("artifacts") or []:
        for part in (artifact or {}).get("parts") or []:
            if isinstance(part, dict) and part.get("text"):
                chunks.append(str(part["text"]))
    return " ".join(chunks)[:2000]


async def a2a_engage(correlation_id: str, action: str, port: int,
                     timeout: float = 12.0, message: Optional[str] = None,
                     authz_ctx: Optional[str] = None) -> Optional[dict]:
    """Hand the action decision to Orbit over A2A, so the exchange between the
    two agents is genuine inter-agent traffic and not only an in-process call.
    Sends a real ``message/send`` to Orbit's own endpoint and returns the task
    ``{"id", "state", "reply_text", "authz_ctx_id"}`` it comes back with
    (``input-required``, the approval pause). ``authz_ctx`` is the COIN token
    Olly carries as the ``X-AuthZ-CTX`` header; Orbit re-validates and narrows
    it before proposing (a token that permits nothing after narrowing is denied
    at the hop, 403). The caller passes the guard-screened ``message``; without
    one a minimal default is used. Best-effort: any failure returns None and the
    caller stays on the in-process decision, so the pipeline never blocks."""
    import httpx

    text = message or (
        f"Propose the next action for correlation_id {correlation_id} "
        f"(Olly's read of the fault points to {action})."
    )
    payload = {
        "jsonrpc": "2.0",
        "id": correlation_id,
        "method": "message/send",
        "params": {"message": {
            "role": "user",
            "messageId": "olly-" + correlation_id,
            "parts": [{"kind": "text", "text": text}],
        }},
    }
    # Carry the token as the AuthZ-CTX and declare the entitlement being
    # delegated (the AuthZ vocabulary, not the proposal verb), so Orbit checks
    # the action it actually holds survives narrowing by its local grant.
    headers = {}
    if authz_ctx:
        headers["X-AuthZ-CTX"] = authz_ctx
        authz_action = AUTHZ_ACTION.get(action, action)
        if authz_action:
            headers["X-AuthZ-Action"] = authz_action
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            resp = await client.post(f"http://127.0.0.1:{port}/", json=payload, headers=headers)
            resp.raise_for_status()
            result = (resp.json() or {}).get("result", {})
            return {
                "id": result.get("id"),
                "state": (result.get("status") or {}).get("state"),
                "reply_text": _extract_reply_text(result),
                "authz_ctx_id": resp.headers.get("X-AuthZ-CTX-Id", ""),
            }
    except Exception as exc:  # noqa: BLE001 - best-effort A2A hand-off
        log.info("orbit A2A hand-off failed (staying on in-process decision): %s", exc)
        return None


def execute(proposal: dict, approved_by: str) -> dict:
    """The deterministic executor, Phase-1 stub.

    In production this runs under a separate write-entitled identity (distinct
    from the agent's read-only role) and drives the real Execution Layer /
    Ansible AAP. Here it records what it *would* do and returns the executed
    proposal, so the full proposed -> approved -> executed flow is real while no
    production system is mutated. Phase 1 stays read-only.

    Returns the proposal with approval.state advanced to ``executed``."""
    action = proposal.get("action")
    app_id = proposal.get("app_id")
    if action == ACTION_REMEDIATE_RESTART:
        detail = (
            f"WOULD restart service for {app_id} via the Execution Layer under the "
            f"write-entitled automation identity (not the agent's read-only role). "
            f"No restart performed in Phase 1."
        )
    elif action == ACTION_TROUBLESHOOT:
        detail = (
            f"WOULD launch a deeper read-only troubleshoot for {app_id}. Read-only, "
            f"so this is safe to run for real in a later phase."
        )
    else:
        detail = f"no_action for {app_id}; nothing to execute."

    log.info(
        'AUDIT {"path":"orbit","action":"%s","proposal_id":"%s","correlation_id":"%s",'
        '"app_id":"%s","approved_by":"%s","executed":true,"mutation":false}',
        action, proposal.get("proposal_id"), proposal.get("correlation_id"),
        app_id, approved_by,
    )

    out = dict(proposal)
    approval = dict(out.get("approval", {}))
    approval["state"] = "executed"
    approval["approved_by"] = approved_by
    out["approval"] = approval
    out["execution_note"] = detail
    return out


def propose_action(correlation_id: str, action: str = "") -> dict:
    """ADK tool: propose one action for a triaged incident, returned in state
    'proposed'. This tool is registered with require_confirmation=True, so ADK
    holds it as an input-required step: nothing executes from the tool call
    itself. Real execution is gated by the signed-approval HTTP path; this tool
    exists so the ADK Studio surface shows the human-in-the-loop step natively.

    The `action` argument is advisory; the action is selected deterministically
    from the incident's fault domain, so a caller cannot request an arbitrary
    action. Returns a summary the confirmation UI can render."""
    return {
        "correlation_id": correlation_id,
        "requested_action": action or "(deterministic)",
        "state": "proposed",
        "note": ("Proposal created in state 'proposed'. It does not execute until "
                 "approved with an ed25519-signed token at /orbit/approve; the "
                 "agent cannot mint that token."),
    }


def build_tool():
    """The propose_action FunctionTool, confirmation-gated. Importable so an
    LlmAgent (or `adk web`) can surface ADK's native tool-confirmation HITL.
    The BaseAgent root does not call tools, so the enforced approval path is
    the signed-JWT HTTP surface; this is the ADK-native view of the same gate."""
    try:
        from google.adk.tools import FunctionTool
    except ImportError:
        return None
    return FunctionTool(propose_action, require_confirmation=True)


ORBIT_A2A_INSTRUCTION = (
    "You are Orbit, the SRE action agent. You have exactly one tool, "
    "propose_action. For every request, call propose_action once, passing the "
    "correlation_id from the user's message (use 'direct' when none is given) "
    "and the action the user named if they named one. Always call the tool; do "
    "not answer in prose. The tool is approval-gated, so it proposes an action "
    "and pauses for a human decision. Nothing executes from your call."
)


def build_orbit_a2a_agent():
    """The Orbit agent for its own A2A endpoint: an LlmAgent whose single tool
    is approval-gated. Because ``propose_action`` requires confirmation, an A2A
    ``message/send`` returns an ``input-required`` task (ADK maps the pending
    confirmation to that state) that the signed approval resolves. Returns
    ``(agent, model_id)``, or ``(None, "")`` without a model, since the pause is
    driven by the model choosing to call the tool."""
    from . import agent as agent_mod
    from google.adk.agents import LlmAgent

    tool = build_tool()
    model, model_id = agent_mod.build_model()
    if model is None or tool is None:
        return None, ""
    log.info("orbit A2A agent active: model=%s", model_id)
    return LlmAgent(
        name="orbit",
        model=model,
        description="Proposes one action-proposal.v1 action, gated on human approval; never acts.",
        instruction=ORBIT_A2A_INSTRUCTION,
        tools=[tool],
    ), model_id
