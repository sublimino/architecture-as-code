"""RBAC + KubeSec-AFM correlation API — the intermediate layer over AFM.

Backs the dashboard's RBAC Explorer (``src/pages/RbacExplorerPage.tsx`` via
``src/api/rbacCorrelationApi.ts``):

    GET /api/rbac/clusters                          -> list[ClusterMeta]
    GET /api/rbac/clusters/{cluster_id}/correlated   -> CorrelatedRbacResponse

Why this exists
----------------
KubeSec-AFM (the ``afm-platform`` D2, see ``d2-k8s-afm/``) exposes cluster
RBAC, escalation analysis, conformance and shared-role findings as four
separate endpoints. The RBAC Explorer used to fetch all four client-side and
stitch them together in the browser, against an assumed AFM wire shape that
was never verified against a live cluster.

Verified against the running ``osramp`` KinD cluster (2026-08-02, see
``docs/signalloom/rbac-live-wiring.md``), that assumed shape was wrong in ways
that silently produced *incorrect security findings*, not just rendering
glitches:

- The old frontend read ``analysis.escalation_paths``. AFM's real top-level
  keys are ``single_escalations`` and ``group_escalations`` —
  ``escalation_paths`` does not exist. The Explorer's "Escalation Paths" stat
  therefore always read 0 against live data, even on a cluster where AFM's Z3
  engine found 3 real privilege-escalation paths (admin-via-impersonation,
  risk level "high"). A security dashboard that silently reports zero
  escalations when there are three is worse than one that errors visibly.
- The old frontend read ``conformance[i].namespace`` and
  ``conformance[i].details`` at the top level. AFM nests the role identity
  (name/scope/namespace) under ``conformance[i].role``, and does not send a
  ``details`` field at all — both columns rendered as "—" on every live row.
- The old frontend read ``shared_roles.results[i].shared_by`` and ``.risk``.
  AFM sends ``all_subjects`` (a list — the count is its length) and
  ``privileged_subjects``, and no ``risk``/``reason`` fields — the
  Shared-Role Pivot Points table rendered "undefined subjects" on every row.

Root cause: AFM's escalation/admin identifiers are its own internal keys
(``sa_fe_signalloom_flux``), not the plain Kubernetes names the RBAC payload
uses (``flux`` / namespace ``fe-signalloom``). Resolving one to the other
requires ``analysis.metadata.name_map``, an internal-id -> "Kind/ns/name"
dictionary that only makes sense to consult once, in one place, against a
version-pinned understanding of the wire format — server-side, not
independently re-derived in every browser tab. That correlation is what this
module does.

Fails closed, not open
-----------------------
Unlike ``/api/health/crypto``'s fail-open behaviour (swallow the error, return
an empty proof list), an unreachable or malformed AFM response here raises
``APIError(503, ...)``. A security-posture tool that silently reports "no
escalations" because its upstream was actually unreachable is a worse failure
mode than a visible 503 — see AISTEERINGRULES "fail visibly" in
docs/signalloom/rbac-live-wiring.md.
"""
from __future__ import annotations

import logging
import os
import re
import socket
from typing import Annotated, Any, Literal
from urllib.parse import urlsplit

import httpx
from fastapi import APIRouter, Depends
from pydantic import BaseModel, ConfigDict, Field

from api_compat import ERROR_RESPONSES, APIError, authenticated_tenant

logger = logging.getLogger(__name__)

AFM_BASE_URL = os.environ.get(
    "AFM_BASE_URL",
    "http://afm-platform.fe-k8s-afm.svc.cluster.local:8000",
)
AFM_TIMEOUT_S = 20.0

# Bound at import time, deliberately. Tests substitute the module's ``httpx``
# attribute with a stand-in namespace exposing only ``AsyncClient`` and
# ``HTTPError``; resolving these classes lazily through ``httpx.`` would then
# raise AttributeError inside the very error path being exercised.
_TimeoutException = httpx.TimeoutException
_HTTPStatusError = httpx.HTTPStatusError

router = APIRouter(prefix="/api/rbac", tags=["rbac"])


# ---------------------------------------------------------------------------
# Wire contract (backend-owned — NOT a passthrough of AFM's raw shape)
# ---------------------------------------------------------------------------


class ClusterMeta(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    name: str


class RoleRule(BaseModel):
    model_config = ConfigDict(extra="forbid")

    verbs: list[str] = Field(default_factory=list)
    apiGroups: list[str] = Field(default_factory=list)
    resources: list[str] = Field(default_factory=list)


class RbacSubject(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str
    kind: str
    namespace: str | None = None
    is_admin: bool = False
    is_escalation_actor: bool = False


class RbacRole(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str
    scope: str
    namespace: str | None = None
    rules: list[RoleRule] = Field(default_factory=list)
    # Correlated server-side from the conformance and shared-role endpoints —
    # this is the "intermediate API" join the frontend used to do per-tab.
    conformance_issue_count: int = 0
    shared_by_count: int = 0
    has_privileged_sharing: bool = False


class RbacBinding(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str
    scope: str
    namespace: str | None = None
    role_ref: str
    subjects: list[RbacSubject] = Field(default_factory=list)


class EscalationFinding(BaseModel):
    model_config = ConfigDict(extra="forbid")

    kind: Literal["single", "group"]
    subject: str
    subject_display: str | None = None
    escalation_type: str | None = None
    risk_level: str | None = None
    risk_score: float | None = None
    summary: str | None = None


class ConformanceFinding(BaseModel):
    model_config = ConfigDict(extra="forbid")

    role_name: str | None = None
    role_scope: str | None = None
    role_namespace: str | None = None
    severity: str | None = None
    reason: str | None = None


class SharedRoleFinding(BaseModel):
    model_config = ConfigDict(extra="forbid")

    role_name: str
    role_scope: str
    role_namespace: str | None = None
    shared_by: int
    subjects: list[str] = Field(default_factory=list)
    privileged_subject_count: int = 0


class CorrelatedRbacResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    cluster: ClusterMeta
    namespaces: list[str] = Field(default_factory=list)
    subjects: list[RbacSubject] = Field(default_factory=list)
    roles: list[RbacRole] = Field(default_factory=list)
    bindings: list[RbacBinding] = Field(default_factory=list)
    escalations: list[EscalationFinding] = Field(default_factory=list)
    conformance: list[ConformanceFinding] = Field(default_factory=list)
    shared_roles: list[SharedRoleFinding] = Field(default_factory=list)
    admin_count: int = 0
    non_admin_count: int = 0


# ---------------------------------------------------------------------------
# Null-tolerant wire parsing helpers
#
# Mirrors src/api/afmApi.ts on the frontend: AFM signals "absent" with an
# explicit `null`, not by omitting the key, so these treat null and missing
# the same way rather than asserting a strict schema.
# ---------------------------------------------------------------------------


def _as_optional_str(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def _as_str_list(value: Any) -> list[str]:
    return [item for item in value if isinstance(item, str)] if isinstance(value, list) else []


def _parse_rule(value: Any) -> RoleRule:
    if not isinstance(value, dict):
        return RoleRule(verbs=[], apiGroups=[""], resources=[])
    api_groups = value.get("apiGroups")
    api_groups = [""] if api_groups is None else _as_str_list(api_groups)
    return RoleRule(verbs=_as_str_list(value.get("verbs")), apiGroups=api_groups, resources=_as_str_list(value.get("resources")))


SubjectKey = tuple[str, str | None, str]


def _subject_key(kind: Any, namespace: Any, name: Any) -> SubjectKey:
    return (str(kind), _as_optional_str(namespace), str(name))


# ---------------------------------------------------------------------------
# AFM identifier resolution
#
# AFM's escalation/admin lists reference subjects by its own internal id
# (e.g. "sa_fe_signalloom_flux"), resolved via analysis.metadata.name_map to
# a "Kind/namespace-or-cluster/name" display string (e.g.
# "ServiceAccount/fe-signalloom/flux"). This is the join key back to the
# plain k8s identity the /rbac endpoint uses.
# ---------------------------------------------------------------------------


def _build_name_lookup(name_map: dict[str, Any]) -> dict[str, SubjectKey]:
    lookup: dict[str, SubjectKey] = {}
    for internal_id, display in name_map.items():
        if not isinstance(display, str):
            continue
        parts = display.split("/", 2)
        if len(parts) != 3:
            continue
        kind, scope_or_ns, name = parts
        namespace = None if scope_or_ns == "cluster" else scope_or_ns
        lookup[internal_id] = (kind, namespace, name)
    return lookup


def _escalation_subject_keys(
    single_escalations: Any, group_escalations: Any, name_lookup: dict[str, SubjectKey],
) -> set[SubjectKey]:
    keys: set[SubjectKey] = set()
    for entry in single_escalations if isinstance(single_escalations, list) else []:
        if not isinstance(entry, dict):
            continue
        subject = entry.get("subject")
        if isinstance(subject, str) and subject in name_lookup:
            keys.add(name_lookup[subject])
    for entry in group_escalations if isinstance(group_escalations, list) else []:
        if not isinstance(entry, dict):
            continue
        subjects = entry.get("subjects")
        candidates = subjects if isinstance(subjects, list) else [entry.get("subject")]
        for subject in candidates:
            if isinstance(subject, str) and subject in name_lookup:
                keys.add(name_lookup[subject])
    return keys


def _admin_subject_keys(metadata: dict[str, Any], name_lookup: dict[str, SubjectKey]) -> set[SubjectKey]:
    keys: set[SubjectKey] = set()
    for internal_id in _as_str_list(metadata.get("admins")) + _as_str_list(metadata.get("full_admins")):
        if internal_id in name_lookup:
            keys.add(name_lookup[internal_id])
    return keys


def _escalation_findings(
    single_escalations: Any, group_escalations: Any, name_map: dict[str, Any],
) -> list[EscalationFinding]:
    findings: list[EscalationFinding] = []
    for entry in single_escalations if isinstance(single_escalations, list) else []:
        if not isinstance(entry, dict):
            continue
        subject = entry.get("subject")
        risk = entry.get("risk") if isinstance(entry.get("risk"), dict) else {}
        trace = entry.get("trace") if isinstance(entry.get("trace"), dict) else {}
        explanation = trace.get("explanation") if isinstance(trace.get("explanation"), dict) else {}
        findings.append(EscalationFinding(
            kind="single",
            subject=subject if isinstance(subject, str) else "unknown",
            subject_display=name_map.get(subject) if isinstance(subject, str) and isinstance(name_map.get(subject), str) else None,
            escalation_type=_as_optional_str(entry.get("escalation_type")),
            risk_level=_as_optional_str(risk.get("level")),
            risk_score=risk.get("score") if isinstance(risk.get("score"), (int, float)) else None,
            summary=_as_optional_str(explanation.get("summary")),
        ))
    for entry in group_escalations if isinstance(group_escalations, list) else []:
        if not isinstance(entry, dict):
            continue
        subjects = entry.get("subjects")
        if isinstance(subjects, list) and subjects:
            subject_label = ", ".join(str(s) for s in subjects if isinstance(s, str))
        else:
            subject_label = _as_optional_str(entry.get("subject")) or "unknown"
        risk = entry.get("risk") if isinstance(entry.get("risk"), dict) else {}
        findings.append(EscalationFinding(
            kind="group",
            subject=subject_label,
            escalation_type=_as_optional_str(entry.get("escalation_type")),
            risk_level=_as_optional_str(risk.get("level")),
            risk_score=risk.get("score") if isinstance(risk.get("score"), (int, float)) else None,
        ))
    return findings


def _conformance_findings(raw: Any) -> list[ConformanceFinding]:
    findings: list[ConformanceFinding] = []
    for item in raw if isinstance(raw, list) else []:
        if not isinstance(item, dict):
            continue
        role = item.get("role") if isinstance(item.get("role"), dict) else {}
        findings.append(ConformanceFinding(
            role_name=_as_optional_str(role.get("name")),
            role_scope=_as_optional_str(role.get("scope")),
            role_namespace=_as_optional_str(role.get("namespace")),
            severity=_as_optional_str(item.get("severity")),
            reason=_as_optional_str(item.get("reason")),
        ))
    return findings


# AFM's shared-role label is "ClusterRole/<name>" or
# "Role/<name> [namespace=<ns>]" — not the {name,scope,namespace} object the
# conformance endpoint uses for the same role identity.
_SHARED_ROLE_LABEL_RE = re.compile(r"^(ClusterRole|Role)/(.+?)(?:\s+\[namespace=(.+)\])?$")


def _parse_shared_role_label(label: str) -> tuple[str, str, str | None] | None:
    match = _SHARED_ROLE_LABEL_RE.match(label)
    if not match:
        return None
    kind, name, namespace = match.groups()
    scope = "Cluster" if kind == "ClusterRole" else "Namespace"
    return name, scope, namespace


def _shared_role_findings(raw: Any) -> list[SharedRoleFinding]:
    results = raw.get("results") if isinstance(raw, dict) else None
    findings: list[SharedRoleFinding] = []
    for item in results if isinstance(results, list) else []:
        if not isinstance(item, dict):
            continue
        label = item.get("role")
        parsed = _parse_shared_role_label(label) if isinstance(label, str) else None
        if parsed is None:
            continue
        name, scope, namespace = parsed
        subjects = _as_str_list(item.get("all_subjects"))
        privileged = item.get("privileged_subjects")
        privileged_count = len(privileged) if isinstance(privileged, list) else 0
        findings.append(SharedRoleFinding(
            role_name=name,
            role_scope=scope,
            role_namespace=namespace,
            shared_by=len(subjects),
            subjects=subjects[:20],
            privileged_subject_count=privileged_count,
        ))
    return findings


RoleKey = tuple[str, str, str | None]


def correlate_rbac(
    cluster_id: str,
    cluster_name: str,
    rbac_raw: dict[str, Any],
    analysis_raw: dict[str, Any],
    conformance_raw: Any,
    shared_roles_raw: Any,
) -> CorrelatedRbacResponse:
    """Pure join of the four AFM payloads. No network I/O — unit-testable."""
    metadata = analysis_raw.get("metadata") if isinstance(analysis_raw.get("metadata"), dict) else {}
    name_map = metadata.get("name_map") if isinstance(metadata.get("name_map"), dict) else {}
    name_lookup = _build_name_lookup(name_map)

    escalation_keys = _escalation_subject_keys(
        analysis_raw.get("single_escalations"), analysis_raw.get("group_escalations"), name_lookup,
    )
    admin_keys = _admin_subject_keys(metadata, name_lookup)
    escalations = _escalation_findings(
        analysis_raw.get("single_escalations"), analysis_raw.get("group_escalations"), name_map,
    )

    conformance = _conformance_findings(conformance_raw)
    conformance_counts: dict[RoleKey, int] = {}
    for issue in conformance:
        if issue.role_name is None or issue.role_scope is None:
            continue
        key: RoleKey = (issue.role_name, issue.role_scope, issue.role_namespace)
        conformance_counts[key] = conformance_counts.get(key, 0) + 1

    shared_roles = _shared_role_findings(shared_roles_raw)
    shared_by_role: dict[RoleKey, SharedRoleFinding] = {
        (s.role_name, s.role_scope, s.role_namespace): s for s in shared_roles
    }

    subjects: list[RbacSubject] = []
    for item in _as_list(rbac_raw.get("subjects")):
        if not isinstance(item, dict):
            continue
        name = _as_optional_str(item.get("name"))
        kind = _as_optional_str(item.get("kind"))
        if name is None or kind is None:
            continue
        namespace = _as_optional_str(item.get("namespace"))
        key = _subject_key(kind, namespace, name)
        subjects.append(RbacSubject(
            name=name, kind=kind, namespace=namespace,
            is_admin=key in admin_keys,
            is_escalation_actor=key in escalation_keys,
        ))

    roles: list[RbacRole] = []
    for item in _as_list(rbac_raw.get("roles")):
        if not isinstance(item, dict):
            continue
        name = _as_optional_str(item.get("name"))
        scope = item.get("scope")
        if name is None or scope not in ("Cluster", "Namespace"):
            continue
        namespace = _as_optional_str(item.get("namespace"))
        rules = [_parse_rule(rule) for rule in _as_list(item.get("rules"))]
        role_key: RoleKey = (name, scope, namespace)
        shared_entry = shared_by_role.get(role_key)
        roles.append(RbacRole(
            name=name, scope=scope, namespace=namespace, rules=rules,
            conformance_issue_count=conformance_counts.get(role_key, 0),
            shared_by_count=shared_entry.shared_by if shared_entry else 0,
            has_privileged_sharing=bool(shared_entry and shared_entry.privileged_subject_count > 0),
        ))

    bindings: list[RbacBinding] = []
    for item in _as_list(rbac_raw.get("bindings")):
        if not isinstance(item, dict):
            continue
        name = _as_optional_str(item.get("name"))
        scope = item.get("scope")
        if name is None or scope not in ("Cluster", "Namespace"):
            continue
        namespace = _as_optional_str(item.get("namespace"))
        role_ref = _as_optional_str(item.get("roleRef")) or ""
        binding_subjects: list[RbacSubject] = []
        for raw_subject in _as_list(item.get("subjects")):
            if not isinstance(raw_subject, dict):
                continue
            s_name = _as_optional_str(raw_subject.get("name"))
            s_kind = _as_optional_str(raw_subject.get("kind"))
            if s_name is None or s_kind is None:
                continue
            s_namespace = _as_optional_str(raw_subject.get("namespace"))
            s_key = _subject_key(s_kind, s_namespace, s_name)
            binding_subjects.append(RbacSubject(
                name=s_name, kind=s_kind, namespace=s_namespace,
                is_admin=s_key in admin_keys,
                is_escalation_actor=s_key in escalation_keys,
            ))
        bindings.append(RbacBinding(
            name=name, scope=scope, namespace=namespace, role_ref=role_ref, subjects=binding_subjects,
        ))

    namespaces_field = _as_str_list(metadata.get("namespaces"))
    if namespaces_field:
        namespaces = sorted(set(namespaces_field))
    else:
        derived = {r.namespace for r in roles if r.namespace}
        derived |= {b.namespace for b in bindings if b.namespace}
        derived |= {s.namespace for s in subjects if s.namespace}
        namespaces = sorted(derived)

    return CorrelatedRbacResponse(
        cluster=ClusterMeta(id=cluster_id, name=cluster_name),
        namespaces=namespaces,
        subjects=subjects,
        roles=roles,
        bindings=bindings,
        escalations=escalations,
        conformance=conformance,
        shared_roles=shared_roles,
        admin_count=len(set(_as_str_list(metadata.get("admins"))) | set(_as_str_list(metadata.get("full_admins")))),
        non_admin_count=len(_as_str_list(metadata.get("non_admins"))),
    )


def _as_list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


# ---------------------------------------------------------------------------
# AFM HTTP client
# ---------------------------------------------------------------------------


async def _afm_get_json(client: httpx.AsyncClient, path: str) -> Any:
    response = await client.get(f"{AFM_BASE_URL}{path}")
    response.raise_for_status()
    return response.json()


# ---------------------------------------------------------------------------
# Failure classification
#
# The 503 is deliberate and stays (see "Fails closed, not open" above) — what
# changes here is that it names the *kind* of failure rather than repeating the
# transport exception verbatim. The page used to render
#
#     KubeSec-AFM is unreachable: [Errno -2] Name or service not known
#
# which is the truth expressed in the least useful available form: an errno is
# not something an operator can act on, and it does not distinguish "the AFM
# slice was never deployed" from "AFM is deployed and refusing connections".
# Those have different fixes. Same principle as api_compat's
# ``fallback_reason`` for the trust topology: carry the reason through, do not
# invent one and do not flatten distinct causes into one string.
# ---------------------------------------------------------------------------


def _afm_host() -> str:
    """The authority (host:port) of AFM_BASE_URL, for operator-facing messages."""
    return urlsplit(AFM_BASE_URL).netloc or AFM_BASE_URL


def _is_dns_failure(exc: BaseException) -> bool:
    """True when the cause chain bottoms out in a name-resolution failure.

    httpx reports a failed lookup as ``ConnectError`` wrapping ``gaierror``, so
    the distinguishing evidence is only ever in the cause chain — the outer
    exception type is identical to a refused connection.
    """
    seen: set[int] = set()
    current: BaseException | None = exc
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        if isinstance(current, socket.gaierror):
            return True
        current = current.__cause__ or current.__context__
    return False


def _afm_failure(exc: Exception, reading: str) -> APIError:
    """Map a transport/decode failure onto an honest, actionable 503."""
    host = _afm_host()
    if _is_dns_failure(exc):
        # No such name means no such Service: the AFM slice is not deployed in
        # this cluster. Naming the fix is the whole point of the distinction.
        return APIError(
            503, "afm_not_deployed",
            f"KubeSec-AFM is not deployed: {host} does not resolve, so {reading} cannot be read. "
            f"Deploy the AFM slice with `make demo-k8s-afm-up`.",
        )
    if isinstance(exc, _TimeoutException):
        return APIError(
            503, "afm_unreachable",
            f"KubeSec-AFM at {host} did not respond within {AFM_TIMEOUT_S:.0f}s while reading {reading}.",
        )
    if isinstance(exc, _HTTPStatusError):
        return APIError(
            503, "afm_unreachable",
            f"KubeSec-AFM at {host} returned HTTP {exc.response.status_code} while reading {reading}.",
        )
    if isinstance(exc, ValueError):
        # Reachable and answering, but not with JSON — a contract break, not an
        # outage, so it is reported as one.
        return APIError(
            503, "afm_bad_response",
            f"KubeSec-AFM at {host} returned a non-JSON response while reading {reading}.",
        )
    return APIError(
        503, "afm_unreachable",
        f"KubeSec-AFM at {host} is deployed but unreachable while reading {reading} "
        f"({type(exc).__name__}). Check its pod status and the NetworkPolicy egress to fe-k8s-afm:8000.",
    )


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.get("/clusters", response_model=list[ClusterMeta], responses=ERROR_RESPONSES)
async def list_clusters(tenant_id: Annotated[str, Depends(authenticated_tenant)]) -> list[ClusterMeta]:
    async with httpx.AsyncClient(timeout=AFM_TIMEOUT_S) as client:
        try:
            payload = await _afm_get_json(client, "/clusters")
        except (httpx.HTTPError, ValueError) as exc:
            logger.warning("rbac_correlation: /clusters unavailable", exc_info=True)
            raise _afm_failure(exc, "the cluster list") from exc

    if not isinstance(payload, list):
        raise APIError(503, "afm_bad_response", "KubeSec-AFM returned a malformed cluster list")

    clusters: list[ClusterMeta] = []
    for item in payload:
        if not isinstance(item, dict):
            continue
        cluster_id = _as_optional_str(item.get("id"))
        if cluster_id is None:
            continue
        clusters.append(ClusterMeta(id=cluster_id, name=_as_optional_str(item.get("name")) or cluster_id))
    return clusters


@router.get(
    "/clusters/{cluster_id}/correlated",
    response_model=CorrelatedRbacResponse,
    responses=ERROR_RESPONSES,
)
async def correlated_rbac(
    cluster_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> CorrelatedRbacResponse:
    async with httpx.AsyncClient(timeout=AFM_TIMEOUT_S) as client:
        # RBAC is the load-bearing call: without it there is nothing to show,
        # so its failure fails the whole request (503) rather than degrading.
        try:
            rbac_raw = await _afm_get_json(client, f"/clusters/{cluster_id}/rbac")
        except (httpx.HTTPError, ValueError) as exc:
            logger.warning("rbac_correlation: RBAC unavailable for cluster %s", cluster_id, exc_info=True)
            raise _afm_failure(exc, f"RBAC data for cluster {cluster_id!r}") from exc
        if not isinstance(rbac_raw, dict):
            raise APIError(
                503, "afm_bad_response",
                f"KubeSec-AFM returned a malformed RBAC payload for cluster {cluster_id!r}",
            )

        cluster_name = cluster_id
        try:
            clusters_raw = await _afm_get_json(client, "/clusters")
            if isinstance(clusters_raw, list):
                for item in clusters_raw:
                    if isinstance(item, dict) and item.get("id") == cluster_id:
                        cluster_name = _as_optional_str(item.get("name")) or cluster_id
                        break
        except (httpx.HTTPError, ValueError):
            pass  # name is cosmetic; fall back to the id rather than fail the request

        # Analysis/conformance/shared-role findings are enrichment: a cluster
        # can be imported before its Z3 analysis job has run, and RBAC
        # browsing should still work in that state. A missing enrichment
        # endpoint degrades those specific fields to empty, not the request.
        analysis_raw: dict[str, Any] = {}
        conformance_raw: list[Any] = []
        shared_roles_raw: dict[str, Any] = {}
        for path, kind in (
            (f"/clusters/{cluster_id}/analysis/latest", "analysis"),
            (f"/clusters/{cluster_id}/rbac/conformance", "conformance"),
            (f"/clusters/{cluster_id}/analysis/shared_roles", "shared_roles"),
        ):
            try:
                payload = await _afm_get_json(client, path)
            except (httpx.HTTPError, ValueError) as exc:
                logger.warning("rbac_correlation: %s unavailable for cluster %s: %s", path, cluster_id, exc)
                continue
            if kind == "analysis" and isinstance(payload, dict):
                analysis_raw = payload
            elif kind == "conformance" and isinstance(payload, list):
                conformance_raw = payload
            elif kind == "shared_roles" and isinstance(payload, dict):
                shared_roles_raw = payload

    return correlate_rbac(cluster_id, cluster_name, rbac_raw, analysis_raw, conformance_raw, shared_roles_raw)


def install_rbac_api(app: Any) -> None:
    app.include_router(router)
