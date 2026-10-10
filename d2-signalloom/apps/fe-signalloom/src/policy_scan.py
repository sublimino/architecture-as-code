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
import math
from collections.abc import Iterable, Mapping
from typing import Any

#: Verdicts the engine may return.  ``error`` means the check could not
#: evaluate; ``not_evaluated`` marks a placeholder check the engine did not run.
#: Neither is ever a pass or a fail.
VERDICTS = ("pass", "fail", "error", "not_evaluated")

# When one control receives several verdicts in one scan, the stored row is
# the least favourable one.
_SEVERITY = {"pass": 0, "not_evaluated": 1, "error": 2, "fail": 3}


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


#: Controller kinds whose pod template is the scan subject.
_TEMPLATE_KINDS = frozenset({"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"})

#: Pack versions none of whose checks reads ``agent`` or ``request``: every
#: evaluated check reads only ``object``.  For an agent with no observed
#: workload such a pack is NOT sent -- the engine binds an absent object to
#: ``{}`` and the CIS checks then fail (or, on a spec with no containers,
#: mostly pass), a verdict about a workload nobody observed.  Its mapped
#: controls are stored ``pending`` and reported as gaps (``no_workload``).
#: Mixed packs (some checks read ``agent``/``request``) are still sent; see
#: ``tests/test_policy_scan_per_agent.py`` for the derivation from the packs.
OBJECT_ONLY_PACKS = frozenset({
    ("cis-kubernetes", "v1.8.0"),
    ("eu-ai-act", "v1.0.0"),
    ("eu-ai-act", "v2.0.0"),
    ("nist-800-53", "v1.0.0"),
    ("nist-800-53", "v2.0.0"),
})


def _has_containers(pod_spec: Any) -> bool:
    if not isinstance(pod_spec, Mapping):
        return False
    containers = pod_spec.get("containers")
    return isinstance(containers, list) and len(containers) > 0


def build_agent_object(row: Mapping[str, Any]) -> dict[str, Any] | None:
    """The ``object`` CEL binding: the agent's Pod-shaped workload, or ``None``.

    Source: ``agent_registry.workload_spec``.  A ``kind: Pod`` is sent as
    recorded; for a Deployment/StatefulSet/DaemonSet/ReplicaSet/Job
    (``spec.template``) or CronJob (``spec.jobTemplate.spec.template``) the pod
    template is sent as ``{"metadata": template.metadata, "spec": template.spec}``,
    as CONFORMANCE.md specifies.  Anything else -- another kind, no kind, or a
    pod spec without a non-empty ``containers`` list -- is not a workload the
    CIS checks can judge, so nothing is sent (``None``).
    """
    workload = _document(row.get("workload_spec"))
    if not isinstance(workload, Mapping):
        return None
    kind = workload.get("kind")
    spec = workload.get("spec")
    if not isinstance(spec, Mapping):
        return None
    if kind == "Pod":
        return dict(workload) if _has_containers(spec) else None
    if kind in _TEMPLATE_KINDS:
        template = spec.get("template")
    elif kind == "CronJob":
        job_template = spec.get("jobTemplate")
        inner = job_template.get("spec") if isinstance(job_template, Mapping) else None
        template = inner.get("template") if isinstance(inner, Mapping) else None
    else:
        return None
    if not isinstance(template, Mapping) or not _has_containers(template.get("spec")):
        return None
    metadata = dict(template.get("metadata") or {})
    # A pod template carries no namespace; the pods run in the controller's,
    # and checks such as no-default-namespace read object.metadata.namespace.
    workload_metadata = workload.get("metadata")
    if "namespace" not in metadata and isinstance(workload_metadata, Mapping) \
            and workload_metadata.get("namespace"):
        metadata["namespace"] = workload_metadata["namespace"]
    return {"metadata": metadata, "spec": dict(template["spec"])}


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


#: The monetary figures every engine result carries (Go ``float64``, never
#: omitted -- see ``policy-engine/compliance.go``).  A result that is missing
#: one, or carries something that is not a finite number there, is not a result
#: this API can report: defaulting it to 0 publishes a figure nobody computed.
MONEY_FIELDS = ("ale", "var95", "tvar", "carriedGbp")


def money_of(result: Mapping[str, Any], field: str) -> float | None:
    """One monetary figure as a finite float, or ``None`` when it is not one.

    ``bool`` is rejected deliberately: it is an ``int`` subclass in Python, and
    ``True`` arriving in ``ale`` is a shape error, not £1.
    """
    value = result.get(field)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    value = float(value)
    return value if math.isfinite(value) else None


def defect_of(result: Mapping[str, Any]) -> str | None:
    """Why this result cannot be read as a verdict, or ``None`` when it can.

    The reason is stored as the check's ``error``.  Every defect here used to
    be silently repaired or fatal: a missing ``status`` and ``passed`` read as
    a fail, a ``None`` or NaN in a money field reached ``float()`` and raised,
    which turned one malformed result into an HTTP 500 for the whole tenant's
    scan.  One unreadable check is one errored check.
    """
    if result.get("status") is None and not isinstance(result.get("passed"), bool):
        return "engine result carried neither status nor passed"
    bad = [field for field in MONEY_FIELDS if money_of(result, field) is None]
    if bad:
        return f"engine result carried no finite number for {', '.join(bad)}"
    return None


def text_of(result: Mapping[str, Any], field: str) -> str | None:
    """A descriptive string the engine may not have sent.

    ``None`` rather than a stand-in: ``calibrationSource`` defaulted to
    ``industry-indicative`` claimed a calibration provenance for a figure whose
    provenance was never reported, and ``scanTimestamp`` defaulted to now
    claimed the engine had just looked.
    """
    value = result.get(field)
    return value if isinstance(value, str) and value else None


def worse(a: str | None, b: str) -> str:
    """The less favourable of two verdicts (fail > error > pass)."""
    if a is None:
        return b
    return a if _SEVERITY[a] >= _SEVERITY[b] else b


def evidence_ref(framework: str, check: str, policy_version: str) -> str:
    """Where a stored verdict came from.  Fits ``evidence_ref VARCHAR(255)``."""
    return f"policy-engine:{framework}/{check}@{policy_version}"[:255]


def stored_status(verdict: str) -> str:
    """The ``agent_compliance_results.status`` for a verdict.

    ``not_evaluated`` is not an assessment, so the control stays ``pending``.
    """
    return "pending" if verdict == "not_evaluated" else verdict
