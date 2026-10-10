"""What the policy engine is asked about an agent, and what its answer means.

Pure functions, no I/O.  ``api_compat._db_policy_scan`` does the database and
HTTP work and calls these to build each agent's scan subject and to read each
verdict.  The wire contract is ``POST /api/v1/compliance/scan`` with body
``{namespace, policyVersion, frameworks, object, agent, request}``; the CEL
bindings are documented in ``policy/frameworks/CONFORMANCE.md``.

The rule every function here follows: a fact the registry does not hold is
absent from the subject.  It is never defaulted, and above all never defaulted
to the compliant value, because a check that reads a defaulted fact reports a
verdict about something nobody observed.
"""
from __future__ import annotations

import json
from collections.abc import Iterable, Mapping
from typing import Any

#: Verdicts the engine may return and the database stores.  ``error`` means the
#: check could not evaluate; it is never a pass and never a fail.
VERDICTS = ("pass", "fail", "error")

# When one control receives several verdicts in one scan (the engine scans
# every version of a pack), the stored row is the least favourable one.
_SEVERITY = {"pass": 0, "error": 1, "fail": 2}


def _document(value: Any) -> Any:
    """A json/jsonb column value: asyncpg hands these over as text without a codec."""
    if isinstance(value, (str, bytes, bytearray)):
        try:
            return json.loads(value)
        except ValueError:
            return None
    return value


def _merge(base: dict[str, Any], override: Mapping[str, Any]) -> dict[str, Any]:
    out = dict(base)
    for key, value in override.items():
        if isinstance(value, Mapping) and isinstance(out.get(key), dict):
            out[key] = _merge(out[key], value)
        else:
            out[key] = value
    return out


def build_agent_policy_context(row: Mapping[str, Any]) -> dict[str, Any]:
    """The ``agent`` CEL binding for one ``agent_registry`` row.

    Mapping (agent context path <- source):

    ========================== ==============================================
    ``registry.model_registered`` ``agent_registry.model_approved`` (boolean;
                               omitted when NULL)
    any other path             ``agent_registry.config -> 'policy_context'``
                               (a JSON object of declared governance facts,
                               e.g. ``guardrails.prompt_injection_filter``,
                               ``governance.decision_explainability``)
    ========================== ==============================================

    Column-derived facts win over a declaration of the same path: the column is
    the registry's system of record, so a declared ``model_registered: true``
    cannot overrule ``model_approved = false``.  A NULL column leaves a
    declared fact in place; with neither, the path is absent.

    The declared document is the extension point for packs that add paths
    (``finos-aigf/v1.0/AGENT-CONTEXT.md``): a new AIGF check needs its fact
    recorded under ``policy_context`` and a ``governance_controls`` seed row,
    not a code change here.
    """
    declared = _document(row.get("policy_context"))
    context: dict[str, Any] = dict(declared) if isinstance(declared, Mapping) else {}

    columns: dict[str, Any] = {}
    model_approved = row.get("model_approved")
    if isinstance(model_approved, bool):
        columns.setdefault("registry", {})["model_registered"] = model_approved

    return _merge(context, columns)


def build_agent_object(row: Mapping[str, Any]) -> dict[str, Any] | None:
    """The ``object`` CEL binding: the agent's Pod-shaped workload, or ``None``.

    Source: ``agent_registry.workload_spec``.  A Pod is sent as recorded; for a
    Deployment/StatefulSet/DaemonSet/Job (``spec.template``) or CronJob
    (``spec.jobTemplate.spec.template``) the pod template is sent as
    ``{"metadata": template.metadata, "spec": template.spec}``, as
    CONFORMANCE.md specifies.  Anything without a pod ``spec`` is not a
    workload the CIS checks can judge, so nothing is sent.
    """
    workload = _document(row.get("workload_spec"))
    if not isinstance(workload, Mapping):
        return None
    spec = workload.get("spec")
    if not isinstance(spec, Mapping):
        return None
    template = spec.get("template")
    job_template = spec.get("jobTemplate")
    if template is None and isinstance(job_template, Mapping):
        inner = job_template.get("spec")
        template = inner.get("template") if isinstance(inner, Mapping) else None
    if template is None:
        return dict(workload)
    if not isinstance(template, Mapping) or not isinstance(template.get("spec"), Mapping):
        return None
    return {"metadata": dict(template.get("metadata") or {}), "spec": dict(template["spec"])}


def scan_request_body(
    *,
    namespace: str,
    policy_version: str,
    frameworks: Iterable[str],
    obj: Mapping[str, Any] | None,
    agent: Mapping[str, Any],
) -> dict[str, Any]:
    """The scan body for one agent.  ``object`` is omitted when there is none."""
    body: dict[str, Any] = {
        "namespace": namespace,
        "policyVersion": policy_version,
        "frameworks": list(frameworks),
    }
    if obj is not None:
        body["object"] = dict(obj)
    body["agent"] = dict(agent)
    body["request"] = {}
    return body


def verdict_of(result: Mapping[str, Any]) -> str:
    """``pass`` / ``fail`` / ``error`` for one engine result.

    ``status`` is authoritative when present.  An engine that predates it
    reports only ``passed``; a boolean there maps to pass/fail.  Anything else
    -- an unknown status, a missing or non-boolean ``passed`` -- is ``error``,
    never a pass.
    """
    status = result.get("status")
    if status is not None:
        return status if status in VERDICTS else "error"
    passed = result.get("passed")
    if isinstance(passed, bool):
        return "pass" if passed else "fail"
    return "error"


def worse(a: str | None, b: str) -> str:
    """The less favourable of two verdicts (fail > error > pass)."""
    if a is None:
        return b
    return a if _SEVERITY[a] >= _SEVERITY[b] else b


def evidence_ref(framework: str, check: str, policy_version: str) -> str:
    """Where a stored verdict came from.  Fits ``evidence_ref VARCHAR(255)``."""
    return f"policy-engine:{framework}/{check}@{policy_version}"[:255]
