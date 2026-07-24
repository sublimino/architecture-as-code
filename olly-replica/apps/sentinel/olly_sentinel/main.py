"""Process entrypoint: the Kafka consume loop (the Self-Healing path) and
the A2A server (card + direct TROUBLESHOOT skill) share one ADK runtime and
one port. Read-only by construction: the only Kafka write is the enrichment
payload onto the response topic; the IO Mapping Service does the ticket
update."""

import asyncio
import json
import logging
import time

import uvicorn
from aiokafka import AIOKafkaConsumer, AIOKafkaProducer
from prometheus_client import make_asgi_app
from starlette.responses import PlainTextResponse

from . import approval, authz, coin, config, decisions, guard, orbit, pipeline
from .a2a_server import build_a2a_app
from .agent import SentinelRuntime
from .metrics import hitl_decisions, hitl_pending, processed, received

# The parked-proposal store: enrichments held for an action decision. The
# Kafka consumer parks into it; the HTTP approve/reject handlers resolve it.
PROPOSALS = approval.ProposalStore()

# Orbit's action agent (an LlmAgent when a model is configured, deterministic
# otherwise). Built once; proposes an action per parked enrichment.
ORBIT = orbit.OrbitRuntime()

# A single producer, shared by the consume loop and the approval resume path,
# so an approval can publish the held-back enrichment. Set in consume_loop.
_producer = None

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger("olly-sentinel")

# Dedup (the same event arrives via the queue and the declined topic) and
# the loop guard (bounded enrichment passes per correlation-ID).
_seen: dict[str, float] = {}
_enriched: dict[str, int] = {}


def _partial(raw: bytes) -> dict:
    """Best-effort identifier recovery from a message that failed schema
    validation, so its rejection still lands on the decision topic under the
    correlation-ID it claimed."""
    try:
        parsed = json.loads(raw)
        return parsed if isinstance(parsed, dict) else {}
    except Exception:  # noqa: BLE001 - unparseable is itself the finding
        return {}


async def handle(runtime: SentinelRuntime, producer: AIOKafkaProducer, raw: bytes) -> None:
    outcome = "failed"
    app_id = "unknown"
    event: dict = {}
    try:
        with pipeline.stage("consume"):
            try:
                event = pipeline.validate_event(raw)
            except Exception as exc:  # noqa: BLE001 - drop events failing schema validation
                log.info("DROP invalid event (schema validation failed, never processed): %s", exc)
                outcome = "rejected"
                received.labels(app_id=app_id, path="kafka").inc()
                await decisions.emit(
                    producer, _partial(raw), "schema_validate", "reject",
                    f"schema validation failed, never processed: {exc}",
                )
                return
        await decisions.emit(producer, event, "schema_validate", "pass",
                             "event validates against eligible-event.v1")

        app_id = event["app_id"]
        # Olly triages Self-Healing-declined events only. The Mapping Service
        # subscription-checks the app and evaluates automation eligibility, and
        # only a declined event carries source "io_declined". Raw events still
        # on the NOI queue (an unsubscribed app, or an eligible event IO
        # auto-remediates) are skipped here; a ticket is enriched only after
        # the decline fills in its app_id.
        if event.get("source") != "io_declined":
            log.info("skip non-declined event %s (app=%s source=%s): Olly triages Self-Healing-declined events only",
                     event["event_id"], app_id, event.get("source"))
            outcome = "skipped"
            await decisions.emit(
                producer, event, "source_filter", "skip",
                f"source={event.get('source')!r}: Olly triages Self-Healing-declined events only",
            )
            return
        received.labels(app_id=app_id, path="kafka").inc()
        event_id, corr = event["event_id"], event["correlation_id"]
        now = time.monotonic()
        if event_id in _seen and now - _seen[event_id] < 3600:
            log.info("dedup: event %s already seen within the hour, skipping (correlation_id=%s)", event_id, corr)
            outcome = "duplicate"
            await decisions.emit(
                producer, event, "dedup", "duplicate",
                "event_id already processed within the 3600s dedup window",
            )
            return
        _seen[event_id] = now
        passes = _enriched.get(corr, 0)
        if passes >= config.MAX_ENRICHMENT_PASSES:
            log.info("loop guard: correlation_id %s already enriched %d time(s), skipping", corr, passes)
            outcome = "loop_guarded"
            await decisions.emit(
                producer, event, "loop_guard", "loop_guarded",
                f"correlation_id already enriched {passes} time(s); limit is {config.MAX_ENRICHMENT_PASSES}",
                enrichment_pass=passes,
            )
            return
        await decisions.emit(producer, event, "source_filter", "pass",
                             "declined event accepted for triage")

        log.info("processing event %s (correlation_id=%s app=%s source=%s)",
                 event_id, corr, event["app_id"], event["source"])
        event["_enrichment_pass"] = passes + 1
        enrichment = await runtime.triage(event)

        # Orbit / HITL: when orbit is enabled, its LlmAgent proposes one action
        # from the closed enum. The enrichment is held for human approval when
        # the proposed action would mutate (remediate_restart_service) or when
        # confidence is below the HITL threshold; a signed token then publishes
        # it via resume_approved(). A troubleshoot or no_action proposal is
        # read-only, so the enrichment publishes and the proposal is advisory.
        # The pending gauge is decremented when the proposal resolves.
        proposal = None
        if config.ORBIT_ENABLED:
            proposal = await ORBIT.propose(enrichment, app_id)
        low_confidence = enrichment["rca"]["confidence_score"] < config.HITL_THRESHOLD
        park = proposal is not None and (
            proposal["action"] == orbit.ACTION_REMEDIATE_RESTART or low_confidence)
        legacy_hitl = (not config.ORBIT_ENABLED and config.HITL_ENABLED
                       and enrichment["rca"]["confidence_score"] < config.HITL_THRESHOLD)
        if park:
            p = approval.Proposal(
                proposal_id=proposal["proposal_id"],
                correlation_id=corr,
                app_id=app_id,
                action=proposal["action"],
                justification=proposal["justification"],
                evidence_refs=proposal.get("evidence_refs", []),
                enrichment=enrichment,
            )
            PROPOSALS.add(p)
            hitl_pending.labels(approver="sre-oncall", app_id=app_id).inc()
            log.info("orbit: enrichment for %s parked as proposal %s (action=%s, confidence %.2f)",
                     corr, p.proposal_id, p.action, enrichment["rca"]["confidence_score"])
            outcome = "parked"

            # Hand the decision to Orbit over A2A as well, so the two agents
            # exchange it as real inter-agent traffic. LLM Guard sits on the hop
            # (Security Sandbox): Olly's message carries the RCA context, so the
            # input scanners screen it before Orbit sees it and the output
            # scanners screen Orbit's reply. Defence in depth behind the
            # redactor: a tripped scan holds the hand-off; a disabled or
            # unreachable guard lets it proceed (the text was already scrubbed).
            handoff = orbit.handoff_message(corr, p.action, enrichment)
            gin = await guard.scan_input(handoff)
            if gin.tripped:
                log.warning("llm-guard held Olly->Orbit hand-off for %s: %s", corr, gin.summary())
                await decisions.emit(
                    producer, event, "llm_guard", "blocked",
                    f"Olly->Orbit message held by LLM Guard: {gin.summary()}",
                    detail={"direction": "input", "proposal_id": p.proposal_id,
                            "scanners": {k: round(float(v), 3) for k, v in gin.scanners.items()}},
                )
            else:
                if gin.ran:
                    await decisions.emit(
                        producer, event, "llm_guard", "scanned",
                        f"Olly->Orbit message cleared LLM Guard input scan ({gin.summary()})",
                        detail={"direction": "input", "proposal_id": p.proposal_id},
                    )
                # The COIN M2M identity behind this hop: the token Olly minted
                # on-behalf-of the human ACME id, its permitted actions, and the
                # authz_ctx_id that anchors the whole chain's audit.
                actx = await coin.MANAGER.context()
                narrowed = authz.intersect(actx.get("permitted_actions", []), config.ORBIT_LOCAL_GRANT)
                narrowed_refs = [f"{a['action']}:{a['limit']}" for a in narrowed]
                narrowed_str = ", ".join(narrowed_refs) or "nothing"
                await decisions.emit(
                    producer, event, "orbit_a2a", "engaged",
                    f"COIN M2M identity minted OBO {config.AUTHZ_ACME_ID} (decision {actx.get('decision')})",
                    detail={"phase": "identity", "proposal_id": p.proposal_id,
                            "authz_ctx_id": actx.get("authz_ctx_id"), "acme_id": config.AUTHZ_ACME_ID,
                            "actor": "agent", "decision": actx.get("decision"),
                            "permitted_actions": [a.get("action") for a in actx.get("permitted_actions", [])]},
                )
                orbit_task = await orbit.a2a_engage(
                    corr, p.action, config.ORBIT_A2A_PORT, message=handoff,
                    authz_ctx=(actx.get("token") or None))
                # The message crossed the wire with X-AuthZ-CTX; Orbit narrowed it
                # by its local grant (never widened) before proposing.
                await decisions.emit(
                    producer, event, "orbit_a2a", "engaged",
                    f"Olly -> Orbit message/send with AuthZ-CTX; narrowed to {narrowed_str} at Orbit",
                    detail={"phase": "handoff", "proposal_id": p.proposal_id, "method": "message/send",
                            "action": p.action, "authz_ctx_id": actx.get("authz_ctx_id"),
                            "narrowed": narrowed_refs},
                )
                if orbit_task and orbit_task.get("state"):
                    gout = await guard.scan_output(handoff, orbit_task.get("reply_text", "") or "")
                    if gout.tripped:
                        await decisions.emit(
                            producer, event, "llm_guard", "blocked",
                            f"Orbit reply flagged by LLM Guard: {gout.summary()}",
                            detail={"direction": "output", "orbit_task_id": orbit_task["id"]},
                        )
                    elif gout.ran:
                        await decisions.emit(
                            producer, event, "llm_guard", "scanned",
                            f"Orbit reply cleared LLM Guard output scan ({gout.summary()})",
                            detail={"direction": "output", "orbit_task_id": orbit_task["id"]},
                        )
                    log.info("orbit A2A: engaged Orbit for %s, task %s is %s (authz_ctx=%s)",
                             corr, orbit_task["id"], orbit_task["state"], orbit_task.get("authz_ctx_id"))
                    await decisions.emit(
                        producer, event, "orbit_a2a", "engaged",
                        f"Orbit returned task {orbit_task['id']} in state {orbit_task['state']}",
                        detail={"phase": "input_required", "proposal_id": p.proposal_id,
                                "orbit_task_id": orbit_task["id"], "state": orbit_task["state"],
                                "authz_ctx_id": orbit_task.get("authz_ctx_id") or actx.get("authz_ctx_id")},
                    )

            await decisions.emit(
                producer, event, "hitl", "parked",
                f"proposed action '{p.action}' awaiting human approval",
                fault_domain=enrichment["rca"]["fault_domain"],
                confidence_score=enrichment["rca"]["confidence_score"],
                enrichment_pass=passes + 1,
                detail={"proposal_id": p.proposal_id, "action": p.action},
            )
            return
        if legacy_hitl:
            hitl_pending.labels(approver="sre-oncall", app_id=app_id).inc()
            log.info("HITL: enrichment for %s parked for approval (confidence %.2f < %.2f)",
                     corr, enrichment["rca"]["confidence_score"], config.HITL_THRESHOLD)
            outcome = "parked"
            await decisions.emit(
                producer, event, "hitl", "parked",
                f"confidence {enrichment['rca']['confidence_score']:.2f} below threshold "
                f"{config.HITL_THRESHOLD:.2f}; awaiting approval",
                fault_domain=enrichment["rca"]["fault_domain"],
                confidence_score=enrichment["rca"]["confidence_score"],
                enrichment_pass=passes + 1,
            )
            return

        with pipeline.stage("publish", app_id):
            await producer.send_and_wait(
                config.RESPONSE_TOPIC,
                json.dumps(enrichment).encode(),
                key=corr.encode(),
            )
        _enriched[corr] = passes + 1
        log.info("enrichment published for correlation_id=%s (pass %d, fault_domain=%s, confidence=%.2f)",
                 corr, passes + 1, enrichment["rca"]["fault_domain"],
                 enrichment["rca"]["confidence_score"])
        outcome = "completed"
        await decisions.emit(
            producer, event, "publish", "complete",
            f"enrichment published to {config.RESPONSE_TOPIC}",
            fault_domain=enrichment["rca"]["fault_domain"],
            confidence_score=enrichment["rca"]["confidence_score"],
            enrichment_pass=passes + 1,
        )
    except Exception as exc:  # noqa: BLE001 - keep consuming
        log.warning("event processing failed: %s", exc)
        await decisions.emit(producer, event, "publish", "fail",
                             f"event processing failed: {exc}")
    finally:
        processed.labels(outcome=outcome, app_id=app_id, path="kafka").inc()


async def resume_approved(proposal_id: str, token: str) -> dict:
    """Approve a parked proposal: verify the signed token binds to it, run the
    stubbed executor, publish the held-back enrichment, and decrement the
    gauge. Raises approval.ApprovalError on any verification failure, and the
    enrichment is published only when the approval verifies."""
    p = PROPOSALS.get(proposal_id)
    if p is None:
        raise approval.ApprovalError("unknown proposal")
    if p.state != "proposed":
        raise approval.ApprovalError(f"proposal already {p.state}")

    # Raises unless the token verifies against the pinned public key and its
    # claims bind to this proposal. Only the broker's approve endpoint holds
    # the key to mint such a token.
    approver = approval.verify_approval(token, p)

    resolved = PROPOSALS.resolve(proposal_id, "approved", approver)
    if resolved is None:
        raise approval.ApprovalError("proposal was already decided")

    executed = orbit.execute(resolved.to_contract(), approver)
    hitl_pending.labels(approver="sre-oncall", app_id=p.app_id).set(
        max(0, _pending_for(p.app_id))
    )
    hitl_decisions.labels(decision="approved", app_id=p.app_id).inc()

    if _producer is not None:
        await _producer.send_and_wait(
            config.RESPONSE_TOPIC,
            json.dumps(p.enrichment).encode(),
            key=p.correlation_id.encode(),
        )
        await decisions.emit(
            _producer, {"correlation_id": p.correlation_id, "event_id": proposal_id, "app_id": p.app_id},
            "publish", "complete",
            f"approved by {approver}; action '{p.action}' executed, enrichment published",
            detail={"proposal_id": proposal_id, "action": p.action, "approved_by": approver},
        )
    log.info("orbit: proposal %s approved by %s, action=%s executed, enrichment published",
             proposal_id, approver, p.action)
    return {"proposal": executed, "approved_by": approver}


async def resume_rejected(proposal_id: str, rejected_by: str) -> dict:
    """Reject a parked proposal: drop the held enrichment, decrement the gauge.
    Rejecting needs no token and is always safe."""
    p = PROPOSALS.get(proposal_id)
    if p is None:
        raise approval.ApprovalError("unknown proposal")
    resolved = PROPOSALS.resolve(proposal_id, "rejected", rejected_by or "operator")
    if resolved is None:
        raise approval.ApprovalError(f"proposal already {p.state}")
    hitl_pending.labels(approver="sre-oncall", app_id=p.app_id).set(
        max(0, _pending_for(p.app_id))
    )
    hitl_decisions.labels(decision="rejected", app_id=p.app_id).inc()
    if _producer is not None:
        await decisions.emit(
            _producer, {"correlation_id": p.correlation_id, "event_id": proposal_id, "app_id": p.app_id},
            "hitl", "reject", f"proposal rejected by {rejected_by or 'operator'}; not published",
            detail={"proposal_id": proposal_id, "action": p.action},
        )
    log.info("orbit: proposal %s rejected by %s; enrichment dropped", proposal_id, rejected_by)
    return {"proposal_id": proposal_id, "state": "rejected"}


def _pending_for(app_id: str) -> int:
    """Count proposals still awaiting a decision for one app; the gauge is set
    from this count so it tracks the store."""
    return sum(1 for p in PROPOSALS.list("proposed") if p.app_id == app_id)


async def consume_loop(runtime: SentinelRuntime) -> None:
    global _producer
    while True:
        try:
            consumer = AIOKafkaConsumer(
                *config.CONSUME_TOPICS,
                bootstrap_servers=config.KAFKA_BROKERS,
                group_id=config.CONSUMER_GROUP,
                auto_offset_reset="earliest",
                enable_auto_commit=True,
            )
            producer = AIOKafkaProducer(bootstrap_servers=config.KAFKA_BROKERS)
            await consumer.start()
            await producer.start()
            _producer = producer
            log.info("olly-sentinel consuming %s (role=%s, hitl=%s, llm=%r)",
                     ",".join(config.CONSUME_TOPICS), config.EEMS_ROLE,
                     config.HITL_ENABLED, config.LLM_URL)
            try:
                async for msg in consumer:
                    await handle(runtime, producer, msg.value)
            finally:
                await consumer.stop()
                await producer.stop()
        except Exception as exc:  # noqa: BLE001 - broker not up yet, keep retrying
            log.warning("kafka loop error: %s (retrying in 5s)", exc)
            await asyncio.sleep(5)


async def _proposals_route(request):
    from starlette.responses import JSONResponse
    state = request.query_params.get("state", "")
    return JSONResponse([p.public_view() for p in PROPOSALS.list(state)])


async def _approve_route(request):
    """Approve a proposal. Body: {proposal_id, token}. The token is the
    ed25519-signed approval JWT; without a valid one the enrichment is not
    published (403)."""
    from starlette.responses import JSONResponse
    try:
        body = await request.json()
    except Exception:  # noqa: BLE001
        return JSONResponse({"error": "body must be JSON"}, status_code=400)
    proposal_id = str(body.get("proposal_id", ""))
    token = str(body.get("token", ""))
    try:
        result = await resume_approved(proposal_id, token)
    except approval.ApprovalError as exc:
        log.warning("orbit approve denied for %s: %s", proposal_id, exc)
        return JSONResponse({"error": str(exc)}, status_code=403)
    return JSONResponse(result)


async def _reject_route(request):
    from starlette.responses import JSONResponse
    try:
        body = await request.json()
    except Exception:  # noqa: BLE001
        return JSONResponse({"error": "body must be JSON"}, status_code=400)
    try:
        result = await resume_rejected(str(body.get("proposal_id", "")),
                                       str(body.get("rejected_by", "")))
    except approval.ApprovalError as exc:
        return JSONResponse({"error": str(exc)}, status_code=404)
    return JSONResponse(result)


def build_app(runtime: SentinelRuntime):
    # ADK's to_a2a registers the JSON-RPC and agent-card routes during the
    # Starlette lifespan; ours are added up front and coexist.
    app = build_a2a_app(runtime)
    app.mount("/metrics", make_asgi_app())
    app.add_route("/healthz", lambda request: PlainTextResponse("ok"))
    # Orbit approval surface. The broker (which holds the private key) mints a
    # token and POSTs it here; verification happens in resume_approved against
    # the public key this process holds.
    app.add_route("/orbit/proposals", _proposals_route, methods=["GET"])
    app.add_route("/orbit/approve", _approve_route, methods=["POST"])
    app.add_route("/orbit/reject", _reject_route, methods=["POST"])
    return app


async def serve() -> None:
    runtime = SentinelRuntime()
    app = build_app(runtime)
    server = uvicorn.Server(uvicorn.Config(
        app, host="0.0.0.0", port=config.LISTEN_PORT, log_level="warning"
    ))
    log.info("A2A server + metrics on :%d (agent card at /.well-known/)", config.LISTEN_PORT)
    coros = [server.serve(), consume_loop(runtime)]

    # Orbit's own A2A endpoint on a second port. Additive: it does not touch the
    # triage endpoint above, and a build failure leaves the main server running.
    if config.ORBIT_ENABLED:
        orbit_app = None
        try:
            from .a2a_server import build_orbit_a2a_app
            orbit_app = build_orbit_a2a_app()
        except Exception as exc:  # noqa: BLE001 - never block the main server
            log.warning("Orbit A2A server not started: %s", exc)
        if orbit_app is not None:
            orbit_server = uvicorn.Server(uvicorn.Config(
                orbit_app, host="0.0.0.0", port=config.ORBIT_A2A_PORT, log_level="warning"
            ))
            log.info("Orbit A2A server on :%d (propose_action returns an input-required task)",
                     config.ORBIT_A2A_PORT)
            coros.append(orbit_server.serve())
        else:
            log.info("Orbit A2A server skipped: no model configured, so nothing calls the gated tool")

    await asyncio.gather(*coros)


def main() -> None:
    asyncio.run(serve())


if __name__ == "__main__":
    main()
