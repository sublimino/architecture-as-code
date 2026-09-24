#!/usr/bin/env python3
"""Generates and applies council-grade card specifications for SLTE.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

# EAPR-P1-3: shared card contract — filename-collision refusal and the D1
# Authorization wire spec carried into every generated card.
_cc_spec = importlib.util.spec_from_file_location(
    "_card_contract", str(Path(__file__).resolve().parent / "_card_contract.py"))
cc = importlib.util.module_from_spec(_cc_spec)
_cc_spec.loader.exec_module(cc)

# Load prompt-contract
pc_spec = importlib.util.spec_from_file_location(
    "prompt_contract",
    "/home/andy/.claude/skills/ajm-auto-kanban/Tools/prompt-contract.py"
)
pc = importlib.util.module_from_spec(pc_spec)
pc_spec.loader.exec_module(pc)

SPEC_DIR = Path.home() / ".cline" / "kanban" / "card-specs" / "SLTE"
SPEC_DIR.mkdir(parents=True, exist_ok=True)

PROPOSAL_PATH = Path(
    "/home/andy/Documents/Obsidian/v1/2. Areas/CEO/Innovation Proposals/"
    "Proposal — SLTE Signal Loom Inbound Agent Registration Engine (2026-Q3).md"
)
CONTRACT_SHA = hashlib.sha256(PROPOSAL_PATH.read_bytes()).hexdigest()

COMMON_OUT_OF_SCOPE = [
    "Modifying existing SLER kernel telemetry modules or eBPF probe definitions.",
    "Modifying SLDP OpenBao Transit key derivation or customer encryption primitives.",
    "Ingesting or logging customer proprietary source code, prompts, or completion tokens.",
    "Hardcoding cloud credentials, API tokens, or static secrets in git-tracked files.",
    "Bypassing cryptographic HMAC-SHA256 signature verification in production.",
    "Permitting unbounded replay attack windows beyond 300 seconds.",
    "Altering core Envoy Ingress Gateway listeners without platform team approval."
]

def make_spec(logical_id: str, band: str, role: str, obj: str, approach: list[str],
              deliverables: list[str], tests: list[str], evidence: list[str],
              failures: list[str], extra_scope: list[str] | None = None) -> dict:
    scope = list(COMMON_OUT_OF_SCOPE)
    if extra_scope:
        scope.extend(extra_scope)
    spec = {
        "logicalId": logical_id,
        "objective": obj.strip(),
        "approach": [a.strip() for a in approach if a.strip()],
        "deliverables": [d.strip() for d in deliverables if d.strip()],
        "testSurface": [t.strip() for t in tests if t.strip()],
        "evidence": [e.strip() for e in evidence if e.strip()],
        "failureModes": [f.strip() for f in failures if f.strip()],
        "outOfScope": [s.strip() for s in scope if s.strip()],
    }
    return spec

SPECS = {}

# P0: S implementation
SPECS["P0"] = make_spec(
    "P0", "S", "implementation",
    obj=(
        "Establish webhook trigger baseline and cryptographic secret test harness for the SLTE mission. "
        "Verify that fe-signalloom test suite runs cleanly under pytest, verify that webhook router seams "
        "exist and are properly mounted, and confirm that the kanban board doctor check passes with zero defects."
    ),
    approach=[
        "Inspect d2-signalloom/apps/fe-signalloom/src/webhook_triggers.py baseline implementation.",
        "Run pytest on fe-signalloom/src/tests/test_webhook_triggers.py to confirm baseline passing state.",
        "Verify webhook secret environment variables (SIGNAL_LOOM_WEBHOOK_SECRET) and fallback mechanics.",
        "Verify integration branch ref refs/heads/integration/slte-v0.1.0 and clean worktree state.",
        "Author baseline report in docs/signalloom/slte-p0-baseline.md documenting test harness readiness."
    ],
    deliverables=[
        "docs/signalloom/slte-p0-baseline.md recording harness identity, existing webhook router inventory, and test baseline.",
        "Clean test run output from fe-signalloom webhook test suite attached as baseline evidence.",
        "Baseline doctor check output proving zero uncompiled cards or broken dependencies in kanban.",
        "Initial test harness fixture in tests/test_webhook_triggers.py asserting test harness readiness."
    ],
    tests=[
        "pytest tests/test_webhook_triggers.py -v",
        "test -f docs/signalloom/slte-p0-baseline.md",
        "git status --porcelain"
    ],
    evidence=[
        "docs/signalloom/slte-p0-baseline.md with citations of all inspected router files.",
        "Captured pytest execution log demonstrating 100% pass on baseline fixtures.",
        "Clean kanban-check doctor output with zero errors.",
        "Errata block appended for SLTE-P0 with status=pass."
    ],
    failures=[
        "Assuming external webhook endpoints can be tested without raw body caching middleware.",
        "Failing to capture existing router list leading to duplicate prefix collisions.",
        "Uncommitted temporary test files dirtying git working tree."
    ]
)

# P1-PRE: S preflight
SPECS["P1-PRE"] = make_spec(
    "P1-PRE", "S", "preflight",
    obj=(
        "Audit webhook signature verification standards, HMAC-SHA256 implementations, and replay attack "
        "protection algorithms. Verify compatibility with GitHub X-Hub-Signature-256 and generic webhook "
        "headers, verify constant-time comparison primitives (hmac.compare_digest), and check timestamp tolerance windows."
    ),
    approach=[
        "Audit RFC 2104 HMAC specifications and GitHub webhook signature standards.",
        "Verify constant-time digest comparison using hmac.compare_digest to prevent timing attacks.",
        "Audit timestamp drift tolerance window (300 seconds) against network latency profiles.",
        "Verify raw request body preservation across FastAPI middleware pipeline.",
        "Draft preflight audit report in docs/signalloom/slte-p1-preflight.md with cryptographic specifications."
    ],
    deliverables=[
        "docs/signalloom/slte-p1-preflight.md detailing cryptographic signature audit and replay defense.",
        "Python signature verification reference snippet matching GitHub specifications.",
        "Timestamp validation formula preventing replay attacks beyond 300 seconds.",
        "Errata block appended for SLTE-P1-PRE in proposal markdown."
    ],
    tests=[
        "pytest tests/test_webhook_triggers.py -k test_verify_github_signature_valid -v",
        "pytest tests/test_webhook_triggers.py -k test_verify_generic_signature_valid_and_replay_protection -v",
        "test -f docs/signalloom/slte-p1-preflight.md"
    ],
    evidence=[
        "docs/signalloom/slte-p1-preflight.md recording verification steps and security analysis.",
        "Captured test output showing successful verification of signature verification routines.",
        "Errata block appended for SLTE-P1-PRE with status=pass."
    ],
    failures=[
        "Using regular string equality instead of hmac.compare_digest introducing timing side-channels.",
        "Permitting timestamp drift exceeding 5 minutes allowing replay attacks.",
        "Consuming request body stream before signature verification causing body read errors."
    ]
)

# P1-1: M implementation (>=450w, >=35l, >=5d, >=4t)
SPECS["P1-1"] = make_spec(
    "P1-1", "M", "implementation",
    obj=(
        "Build the cryptographic HMAC-SHA256 signature verifier and raw body caching middleware in "
        "d2-signalloom/apps/fe-signalloom/src/webhook_triggers.py. Implement verify_github_signature "
        "validating X-Hub-Signature-256 headers using hmac.compare_digest. Implement verify_generic_signature "
        "validating X-SignalLoom-Signature and X-SignalLoom-Timestamp headers with a strict 300-second maximum "
        "drift ceiling. Ensure raw request bytes are preserved during FastAPI request handling to prevent stream "
        "exhaustion. Write comprehensive unit tests in tests/test_webhook_triggers.py covering valid signatures, "
        "tampered payloads, missing headers, expired timestamps, and malformed encoding."
    ),
    approach=[
        "Define verify_github_signature(payload_bytes: bytes, secret: str, signature_header: Optional[str]) -> bool.",
        "Extract sha256= prefix and compute expected HMAC-SHA256 hex digest over raw bytes.",
        "Compare received and expected hashes using constant-time hmac.compare_digest.",
        "Define verify_generic_signature with timestamp drift validation against UTC now.",
        "Reject requests where client timestamp differs from server time by more than 300 seconds.",
        "Construct raw body signing string f'{timestamp}.'.encode() + payload_bytes.",
        "Implement tenant-specific webhook secret lookup helper get_webhook_secret(tenant_key).",
        "Write unit tests verifying GitHub signature pass and fail conditions.",
        "Write unit tests verifying generic signature replay rejection on timestamps > 300s old.",
        "Write unit tests testing future timestamp spoofing defense.",
        "Document signature verification contracts in docs/signalloom/slte-p1-signature-verifier.md."
    ],
    deliverables=[
        "HMAC-SHA256 signature verification functions in fe-signalloom/src/webhook_triggers.py.",
        "Timestamp replay attack defense logic enforcing 300-second drift boundaries.",
        "Comprehensive unit test suite in fe-signalloom/src/tests/test_webhook_triggers.py.",
        "Tenant-specific webhook secret derivation helper with environment variable overrides.",
        "docs/signalloom/slte-p1-signature-verifier.md detailing cryptographic protocols and header formats.",
        "Append-only errata entry for SLTE-P1-1 in proposal markdown."
    ],
    tests=[
        "pytest tests/test_webhook_triggers.py -k test_verify_github_signature_valid -v",
        "pytest tests/test_webhook_triggers.py -k test_verify_generic_signature_valid_and_replay_protection -v",
        "pytest tests/test_webhook_triggers.py -k test_webhook_secret_resolution -v",
        "pytest tests/test_webhook_triggers.py -v"
    ],
    evidence=[
        "Captured pytest execution log demonstrating 100% pass on signature verification tests.",
        "Security audit transcript confirming constant-time comparison across 1,000 synthetic payloads.",
        "docs/signalloom/slte-p1-signature-verifier.md with complete function signatures and docstrings.",
        "Errata block appended for SLTE-P1-1 with status=pass."
    ],
    failures=[
        "Failing to enforce constant-time equality check enabling timing side-channel attacks.",
        "Allowing negative timestamp drifts (future timestamps) to bypass replay checks.",
        "Truncating the HMAC digest or computing over decoded unicode rather than raw bytes.",
        "Leaking webhook secrets or internal signing keys in error logs."
    ]
)

# P1-2: M implementation (>=450w, >=35l, >=5d, >=4t)
SPECS["P1-2"] = make_spec(
    "P1-2", "M", "implementation",
    obj=(
        "Define webhook payload schemas, event models, and trigger actions in "
        "d2-signalloom/apps/fe-signalloom/src/webhook_triggers.py. Author Pydantic v2 models for "
        "GitHubPullRequestPayload, GenericTriggerPayload, and WebhookTriggerResponse. Implement schema "
        "validations enforcing required event fields, action types ('opened', 'reopened', 'synchronize', 'closed', "
        "'provision', 'teardown'), and tenant company normalization. Enforce strict extra='forbid' rules to prevent "
        "payload smuggling. Implement mapping helpers translating webhook events into EAP environment provisioning actions."
    ),
    approach=[
        "Define GitHubPullRequestPayload model with repository, action, number, and pull_request metadata.",
        "Define GenericTriggerPayload model with company_name, action, ttl_minutes, and metadata.",
        "Configure model_config = ConfigDict(extra='forbid', str_strip_whitespace=True) on all models.",
        "Implement normalize_company_name integration extracting tenant identifier from repo name or payload.",
        "Define WebhookTriggerResponse model returning status, action_taken, customer_hash, and mesh URLs.",
        "Enforce action enum constraints preventing invalid or unsupported trigger operations.",
        "Implement event deduplication helper using delivery GUIDs (X-GitHub-Delivery, X-SignalLoom-Event-ID).",
        "Write unit tests verifying schema deserialization, field validations, and error boundaries.",
        "Add unit tests for company name extraction across various GitHub repository naming conventions.",
        "Document webhook payload schemas in docs/signalloom/slte-p1-payload-schemas.md."
    ],
    deliverables=[
        "Pydantic data models for GitHub and generic webhooks in fe-signalloom/src/webhook_triggers.py.",
        "Tenant company extraction helper resolving customer names from repository strings.",
        "WebhookTriggerResponse model providing structured JSON responses with routing details.",
        "Unit test suite in fe-signalloom/src/tests/test_webhook_schemas.py.",
        "docs/signalloom/slte-p1-payload-schemas.md documenting schema definitions and JSON examples.",
        "Append-only errata entry for SLTE-P1-2 in proposal markdown."
    ],
    tests=[
        "pytest tests/test_webhook_triggers.py -k test_api_github_webhook_pr_lifecycle -v",
        "pytest tests/test_webhook_triggers.py -k test_api_generic_webhook_trigger -v",
        "pytest tests/test_webhook_triggers.py -v",
        "python3 -c \"from webhook_triggers import WebhookTriggerResponse; print(WebhookTriggerResponse.model_json_schema())\""
    ],
    evidence=[
        "Captured pytest execution log demonstrating 100% pass on schema validation tests.",
        "OpenAPI JSON schema dump verifying valid schema generation from webhook models.",
        "docs/signalloom/slte-p1-payload-schemas.md with complete schema documentation.",
        "Errata block appended for SLTE-P1-2 with status=pass."
    ],
    failures=[
        "Permitting unknown fields in payload bodies enabling payload tampering or injection.",
        "Failing to handle missing repository fields in malformed GitHub webhook payloads.",
        "Assuming company name is always explicit rather than falling back to repo name heuristics."
    ]
)

# P1-GOV: M governor (>=450w, >=35l, >=5d, tests exempt)
SPECS["P1-GOV"] = make_spec(
    "P1-GOV", "M", "governor",
    obj=(
        "Phase 1 Governor Certification: independently verify webhook signature security, replay rejection, "
        "and payload schema parsing. Conduct automated adversarial testing against signature verifiers: verify that "
        "bit-flipped payloads, forged headers, truncated hashes, and replayed timestamps (>300s) are unconditionally "
        "rejected with HTTP 401. Audit code quality, typing compliance, and documentation in webhook_triggers.py. "
        "Reconcile Phase 1 commits into integration branch integration/slte-v0.1.0, update proposal errata, and "
        "certify readiness for Phase 2 REST API endpoint development."
    ),
    approach=[
        "Review git diff of all Phase 1 commits in webhook_triggers.py.",
        "Execute automated adversarial test suite with 1,000 forged and tampered webhook payloads.",
        "Verify that zero forged payloads pass signature verification.",
        "Audit constant-time comparison primitives ensuring protection against timing attacks.",
        "Confirm that kanban doctor check reports zero graph anomalies or orphaned cards.",
        "Author Phase 1 certification document in docs/signalloom/slte-p1-certification.md.",
        "Append qualified Phase 1 completion errata block to proposal markdown."
    ],
    deliverables=[
        "docs/signalloom/slte-p1-certification.md certifying Phase 1 signature security and schema parsing.",
        "Automated governor verification script executing adversarial signature test sweep.",
        "Captured test output demonstrating 100% pass across all security assertions.",
        "Clean kanban-check doctor status report.",
        "Phase 1 Governor errata block appended to proposal markdown with status=pass."
    ],
    tests=[
        "pytest tests/test_webhook_triggers.py -v",
        "~/.claude/skills/ajm-auto-kanban/Tools/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLTE"
    ],
    evidence=[
        "docs/signalloom/slte-p1-certification.md signed with verification artifacts.",
        "Green test run outputs demonstrating zero defects across security test suites.",
        "Clean doctor output verifying healthy board state.",
        "Errata block appended for SLTE-P1-GOV with status=pass."
    ],
    failures=[
        "Certifying Phase 1 while any forged signature payload passes verification.",
        "Overlooking timing side-channels in signature comparison routines.",
        "Failing to capture complete cryptographic rationale in documentation."
    ]
)

# P2-PRE: S preflight (>=250w, >=20l, >=4d, tests exempt)
SPECS["P2-PRE"] = make_spec(
    "P2-PRE", "S", "preflight",
    obj=(
        "Audit FastAPI webhook endpoint mount seams, route prefix conventions, and rate limiting hooks in "
        "fe-signalloom/src/main.py. Confirm that /api/v1/webhooks mounts cleanly without path collisions, verify "
        "error handling middleware behavior for HTTP 401 and 400 responses, and audit dependency injection mechanisms "
        "connecting webhooks to the environment registry."
    ),
    approach=[
        "Inspect fe-signalloom/src/main.py ensuring /api/v1/webhooks router prefix is uniquely mounted.",
        "Audit exception handlers ensuring HTTP 401 Unauthorized returns structured JSON without leaking tracebacks.",
        "Verify raw body caching middleware mechanics across async request lifecycle.",
        "Inspect connection between webhook router and GLOBAL_ENVIRONMENT_REGISTRY.",
        "Draft preflight audit report in docs/signalloom/slte-p2-preflight.md with router mount specifications."
    ],
    deliverables=[
        "docs/signalloom/slte-p2-preflight.md detailing router mount seams, exception handling, and registry hooks.",
        "Router mounting blueprint function install_webhook_triggers_api(app).",
        "Exception response format specification for webhook endpoints.",
        "Errata block appended for SLTE-P2-PRE in proposal markdown."
    ],
    tests=[
        "pytest tests/test_webhook_triggers.py -k test_api_github_webhook_unauthorized_without_signature -v",
        "test -f docs/signalloom/slte-p2-preflight.md",
        "git status --porcelain"
    ],
    evidence=[
        "docs/signalloom/slte-p2-preflight.md with complete router seam analysis.",
        "Captured test output showing clean preflight execution.",
        "Errata block appended for SLTE-P2-PRE with status=pass."
    ],
    failures=[
        "Mounting webhook router at conflicting path overlapping with existing API endpoints.",
        "Leaking internal exception details in HTTP 500 error responses.",
        "Failing to verify registry dependency injection before building trigger handlers."
    ]
)

# P2-1: L implementation (>=700w, >=50l, >=6d, >=5t)
SPECS["P2-1"] = make_spec(
    "P2-1", "L", "implementation",
    obj=(
        "Implement core webhook trigger REST endpoints in d2-signalloom/apps/fe-signalloom/src/webhook_triggers.py. "
        "Build POST /api/v1/webhooks/github accepting GitHub webhook deliveries with X-Hub-Signature-256 and X-GitHub-Event "
        "headers. Build POST /api/v1/webhooks/generic accepting generic CI/CD triggers with X-SignalLoom-Signature and "
        "X-SignalLoom-Timestamp headers. Enforce fail-closed cryptographic signature verification returning HTTP 401 on "
        "any verification failure. Parse payload bodies into typed Pydantic models, extract normalized customer identity "
        "(e.g. kurasi -> 6f82ad81), compute internal mesh URL (https://sl-eap-6f82ad81.tailscale) and MagicDNS FQDN, "
        "and return structured WebhookTriggerResponse with HTTP 200 OK. Wire router into main.py via install_webhook_triggers_api "
        "and write exhaustive FastAPI TestClient test suites."
    ),
    approach=[
        "Create APIRouter(prefix='/api/v1/webhooks', tags=['webhooks']) in webhook_triggers.py.",
        "Implement POST /github endpoint accepting Request, X-Hub-Signature-256, X-GitHub-Event, and X-GitHub-Delivery.",
        "Read raw body asynchronously and verify signature using verify_github_signature.",
        "Raise HTTPException(401, 'Invalid or missing X-Hub-Signature-256') on signature mismatch.",
        "Parse payload JSON and route based on X-GitHub-Event header.",
        "Implement POST /generic endpoint accepting Request, X-SignalLoom-Signature, and X-SignalLoom-Timestamp.",
        "Verify generic signature using verify_generic_signature with timestamp drift check.",
        "Extract company_name, action, and ttl_minutes from generic payload.",
        "Implement install_webhook_triggers_api(app: FastAPI) helper mounting router.",
        "Update main.py to call install_webhook_triggers_api during startup.",
        "Write comprehensive TestClient tests in tests/test_webhook_triggers.py covering GitHub and generic endpoints.",
        "Test canonical kurasi vector verification in webhook responses.",
        "Document OpenAPI endpoints, curl request examples, and signature computation in docs/signalloom/slte-p2-api-endpoints.md."
    ],
    deliverables=[
        "FastAPI webhook router in fe-signalloom/src/webhook_triggers.py implementing /github and /generic.",
        "Router installation helper install_webhook_triggers_api wired into fe-signalloom/src/main.py.",
        "Comprehensive API test suite in fe-signalloom/src/tests/test_webhook_triggers.py with 100% endpoint coverage.",
        "Canonical kurasi webhook verification test asserting hash 6f82ad81 and mesh URL in response.",
        "Error handling test cases covering 400 Bad Request and 401 Unauthorized status codes.",
        "docs/signalloom/slte-p2-api-endpoints.md detailing OpenAPI schemas and HMAC header examples.",
        "Append-only errata entry for SLTE-P2-1 in proposal markdown."
    ],
    tests=[
        "pytest tests/test_webhook_triggers.py -k test_api_github_webhook_unauthorized_without_signature -v",
        "pytest tests/test_webhook_triggers.py -k test_api_github_webhook_pr_lifecycle -v",
        "pytest tests/test_webhook_triggers.py -k test_api_generic_webhook_trigger -v",
        "pytest tests/test_webhook_triggers.py -v",
        "pytest tests/test_environment_routing.py -v"
    ],
    evidence=[
        "Captured pytest execution log demonstrating 100% pass across webhook trigger endpoints.",
        "HTTP response transcript proving GitHub webhook triggers environment provisioning for kurasi.",
        "docs/signalloom/slte-p2-api-endpoints.md with complete OpenAPI specification extracts.",
        "Errata block appended for SLTE-P2-1 with status=pass."
    ],
    failures=[
        "Returning HTTP 200 on invalid signatures bypassing security gates.",
        "Consuming request body stream destructively before signature verification.",
        "Leaking internal exception details in HTTP 500 error payloads.",
        "Failing to normalize customer company names before hash derivation."
    ]
)

# P2-2: L implementation (>=700w, >=50l, >=6d, >=5t)
SPECS["P2-2"] = make_spec(
    "P2-2", "L", "implementation",
    obj=(
        "Implement event dispatcher wiring webhook events directly into the on-demand EAP environment provisioning engine. "
        "In fe-signalloom/src/webhook_triggers.py, connect incoming GitHub pull request actions to environment lifecycle states: "
        "action 'opened' or 'reopened' automatically triggers environment provisioning via GLOBAL_ENVIRONMENT_REGISTRY.create; "
        "action 'synchronize' (new commits pushed to PR) triggers TTL lease extension via GLOBAL_ENVIRONMENT_REGISTRY.extend_ttl; "
        "action 'closed' automatically triggers orderly de-provisioning and teardown via GLOBAL_ENVIRONMENT_REGISTRY.teardown. "
        "Implement delivery deduplication cache preventing duplicate provisioning actions on retried webhook events. "
        "Write extensive integration tests verifying state transitions across the full PR lifecycle."
    ),
    approach=[
        "Connect webhook handlers to GLOBAL_ENVIRONMENT_REGISTRY in environment_routing.py.",
        "Implement dispatch_github_event(event_type: str, payload: dict, delivery_id: str) helper.",
        "In dispatch_github_event, handle 'pull_request.opened' by invoking registry.create with 120-minute default TTL.",
        "Handle 'pull_request.synchronize' by finding active environment and calling registry.extend_ttl(60).",
        "Handle 'pull_request.closed' by finding active environment and calling registry.teardown.",
        "Handle duplicate active environments gracefully: if already active on PR opened, return existing environment details.",
        "Implement delivery GUID deduplication cache storing processed delivery IDs for 24 hours.",
        "Emit structured audit telemetry events on every webhook dispatch action.",
        "Write integration test in tests/test_webhook_triggers.py testing sequential lifecycle: opened -> sync -> closed.",
        "Test deduplication: sending identical delivery GUID twice executes provisioning action exactly once.",
        "Document event dispatching rules and lifecycle mappings in docs/signalloom/slte-p2-dispatcher.md."
    ],
    deliverables=[
        "Event dispatcher implementation connecting webhooks to environment registry in fe-signalloom/src/webhook_triggers.py.",
        "GitHub PR action handlers for opened, synchronize, and closed events.",
        "Delivery deduplication cache preventing double-provisioning on webhook retries.",
        "Integration test suite in fe-signalloom/src/tests/test_webhook_triggers.py verifying full PR lifecycle.",
        "docs/signalloom/slte-p2-dispatcher.md detailing event-to-lifecycle mapping architecture.",
        "Append-only errata entry for SLTE-P2-2 in proposal markdown."
    ],
    tests=[
        "pytest tests/test_webhook_triggers.py -k test_api_github_webhook_pr_lifecycle -v",
        "pytest tests/test_webhook_triggers.py -k test_api_generic_webhook_trigger -v",
        "pytest tests/test_webhook_triggers.py -v",
        "pytest tests/ -v"
    ],
    evidence=[
        "Captured pytest execution log demonstrating 100% pass across event dispatcher tests.",
        "Execution trace showing automated progression: PR opened -> provisioned -> PR closed -> terminated.",
        "docs/signalloom/slte-p2-dispatcher.md with complete lifecycle sequence diagrams.",
        "Errata block appended for SLTE-P2-2 with status=pass."
    ],
    failures=[
        "Failing to handle duplicate PR opened events resulting in 409 error rather than returning existing environment.",
        "Allowing PR closed events to fail when environment is already terminated.",
        "Memory leaks in delivery deduplication cache under sustained webhook traffic."
    ]
)

# P2-GOV: M governor (>=450w, >=35l, >=5d, tests exempt)
SPECS["P2-GOV"] = make_spec(
    "P2-GOV", "M", "governor",
    obj=(
        "Phase 2 Governor Certification: independently verify all REST API endpoints for webhook triggers, "
        "event dispatching, and environment lifecycle integration. Audit OpenAPI schema generation, verify HTTP status "
        "code contracts (200 OK, 400 Bad Request, 401 Unauthorized), test concurrent webhook requests for thread safety, and "
        "confirm that the kurasi canonical vector provisions and tears down flawlessly via webhook triggers. Reconcile all "
        "Phase 2 code into the integration branch, run the full test suite, author certification documentation, and certify "
        "readiness for Phase 3 Ingress and CLI emitter automation."
    ),
    approach=[
        "Review git diff of all Phase 2 commits in webhook_triggers.py and main.py.",
        "Execute full test suite across fe-signalloom ensuring 100% pass with zero regressions.",
        "Run concurrent webhook stress test issuing 50 simulated parallel requests to verify registry thread safety.",
        "Audit OpenAPI schema generated at /openapi.json ensuring accurate type definitions and status codes.",
        "Verify that kurasi canonical vector correctly yields https://sl-eap-6f82ad81.tailscale via webhook call.",
        "Check kanban board health with kanban-check doctor ensuring zero anomalies.",
        "Author Phase 2 certification document in docs/signalloom/slte-p2-certification.md.",
        "Append qualified Phase 2 completion errata block to proposal markdown."
    ],
    deliverables=[
        "docs/signalloom/slte-p2-certification.md detailing Phase 2 webhook API validation and concurrency audit.",
        "Automated governor verification script executing end-to-end webhook test against TestClient.",
        "Captured test output showing 100% pass across all webhook trigger test suites.",
        "Clean kanban-check doctor status report.",
        "Phase 2 Governor errata block appended to proposal markdown with status=pass."
    ],
    tests=[
        "pytest tests/test_webhook_triggers.py tests/test_environment_routing.py -v",
        "pytest tests/ -v",
        "~/.claude/skills/ajm-auto-kanban/Tools/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLTE"
    ],
    evidence=[
        "docs/signalloom/slte-p2-certification.md signed with verification artifacts.",
        "Green test run outputs demonstrating zero failures across all test suites.",
        "Clean doctor output verifying healthy board state.",
        "Errata block appended for SLTE-P2-GOV with status=pass."
    ],
    failures=[
        "Certifying Phase 2 while any endpoint test fails or exhibits race conditions under concurrency.",
        "Overlooking signature verification bypasses under specific header encodings.",
        "Merging unformatted or unlinted code into the integration branch."
    ]
)

# P3-PRE: S preflight (>=250w, >=20l, >=4d, tests exempt)
SPECS["P3-PRE"] = make_spec(
    "P3-PRE", "S", "preflight",
    obj=(
        "Audit Envoy Ingress webhook route definitions, Gateway API routing rules, and external secret storage for "
        "webhook receivers. Verify how public webhook traffic targeting /api/v1/webhooks/* is routed through Envoy Gateway "
        "into fe-signalloom, confirm that webhook paths bypass client authentication middleware while preserving raw headers, "
        "and audit secret injection mechanisms before authoring Ingress manifests and CLI emitter scripts."
    ),
    approach=[
        "Inspect Envoy Gateway cluster gateway configuration in d2-infra/components/ingress/.",
        "Verify that HTTPRoute rules allow unauthenticated ingress on path prefix /api/v1/webhooks/.",
        "Ensure X-Hub-Signature-256 and X-SignalLoom-* headers are preserved without Envoy proxy stripping.",
        "Audit Kubernetes Secret mounting for SIGNAL_LOOM_WEBHOOK_SECRET in fe-signalloom deployment.",
        "Draft preflight audit report in docs/signalloom/slte-p3-preflight.md with ingress routing specifications."
    ],
    deliverables=[
        "docs/signalloom/slte-p3-preflight.md detailing Envoy webhook ingress rules, header preservation, and secrets.",
        "Envoy HTTPRoute manifest draft for public webhook receiver endpoints.",
        "Header preservation audit verifying X-Hub-Signature-256 passes untouched.",
        "Errata block appended for SLTE-P3-PRE in proposal markdown."
    ],
    tests=[
        "test -f docs/signalloom/slte-p3-preflight.md",
        "pytest tests/test_webhook_triggers.py -v",
        "git status --porcelain"
    ],
    evidence=[
        "docs/signalloom/slte-p3-preflight.md documenting all verified ingress routing rules.",
        "Captured test output showing clean preflight probe execution.",
        "Errata block appended for SLTE-P3-PRE with status=pass."
    ],
    failures=[
        "Applying authentication filters to webhook endpoints preventing external GitHub deliveries from reaching backend.",
        "Stripping custom headers (X-Hub-Signature-256) in Envoy Ingress Gateway.",
        "Hardcoding webhook secrets in manifest files."
    ]
)

# P3-1: L implementation (>=700w, >=50l, >=6d, >=5t)
SPECS["P3-1"] = make_spec(
    "P3-1", "L", "implementation",
    obj=(
        "Author Envoy Ingress Gateway HTTPRoute for public webhook receivers in d2-infra/components/ingress/webhook-httproute.yaml. "
        "Define Gateway API HTTPRoute rules matching hostname *.${CLUSTER_DOMAIN} on path prefix /api/v1/webhooks/, routing "
        "traffic directly to the fe-signalloom backend service on port 8080. Configure rate limiting and connection timeout "
        "policies preventing denial-of-service attacks from abusive external webhook emitters. Implement automated manifest "
        "validation scripts ensuring compatibility with Gateway API gateway.networking.k8s.io/v1. Write deployment validation tests."
    ),
    approach=[
        "Author d2-infra/components/ingress/webhook-httproute.yaml using Gateway API v1.",
        "Attach parentRef to Gateway cluster in ingress namespace.",
        "Configure route rule with PathPrefix match on /api/v1/webhooks/.",
        "Route backendRef to dashboard-signalloom service on port 8080.",
        "Configure timeout policies: request timeout 10s, backend timeout 8s to fail fast on stalled handlers.",
        "Add Envoy rate limit policy attachment restricting external webhook traffic to 100 requests per minute per IP.",
        "Ensure X-Hub-Signature-256, X-GitHub-Event, and X-SignalLoom-* headers are preserved on upstream requests.",
        "Author manifest validation script scripts/eap/validate-webhook-ingress.sh.",
        "Test manifest syntax and schema validity using kubeconform or kubectl dry-run if available.",
        "Document webhook ingress routing architecture in docs/signalloom/slte-p3-ingress.md."
    ],
    deliverables=[
        "Envoy Ingress Gateway HTTPRoute manifest in d2-infra/components/ingress/webhook-httproute.yaml.",
        "Rate limiting policy attachment protecting webhook receiver endpoints.",
        "Header preservation and timeout policy configuration for webhook routing.",
        "Manifest validation script scripts/eap/validate-webhook-ingress.sh.",
        "docs/signalloom/slte-p3-ingress.md detailing ingress topology and rate limiting parameters.",
        "Append-only errata entry for SLTE-P3-1 in proposal markdown."
    ],
    tests=[
        "bash scripts/eap/validate-webhook-ingress.sh",
        "pytest tests/test_webhook_triggers.py -v",
        "pytest tests/ -v"
    ],
    evidence=[
        "Captured validation log demonstrating 100% schema compliance for webhook HTTPRoute manifest.",
        "Rendered YAML manifest proving valid Envoy Gateway route configuration.",
        "docs/signalloom/slte-p3-ingress.md with complete routing architecture diagrams.",
        "Errata block appended for SLTE-P3-1 with status=pass."
    ],
    failures=[
        "Misconfiguring path prefix causing webhook traffic to be intercepted by single-page application frontend.",
        "Setting excessively strict rate limits that block legitimate bursts of GitHub webhook deliveries.",
        "Failing to validate YAML syntax against Gateway API CRD schemas."
    ]
)

# P3-2: L implementation (>=700w, >=50l, >=6d, >=5t)
SPECS["P3-2"] = make_spec(
    "P3-2", "L", "implementation",
    obj=(
        "Build the synthetic webhook emitter CLI tool in scripts/eap/emit-eap-webhook.sh. Implement subcommands to simulate "
        "real-world CI/CD webhook events: 'github-pr' to emit a signed GitHub pull_request webhook payload with X-Hub-Signature-256; "
        "'generic' to emit a signed generic CI/CD payload with X-SignalLoom-Signature and current timestamp; and 'tamper' to "
        "intentionally emit corrupted or expired signatures for negative security verification. Support TARGET_URL configuration "
        "(defaulting to http://localhost:8080/api/v1/webhooks). Author comprehensive test suite scripts/eap/test_emit_eap_webhook.sh "
        "exercising all CLI subcommands against the live or mock FastAPI application."
    ),
    approach=[
        "Create scripts/eap/emit-eap-webhook.sh with strict bash flags (set -euo pipefail).",
        "Implement HMAC-SHA256 signature generator using openssl dgst -sha256 -hmac or python3 fallback.",
        "Implement github-pr subcommand accepting company, pr_number, action (opened, sync, closed).",
        "In github-pr, construct JSON payload, compute X-Hub-Signature-256, and POST via curl.",
        "Implement generic subcommand accepting company, action, ttl_minutes, computing X-SignalLoom-Signature.",
        "Implement tamper subcommand introducing intentional single-bit errors into signature for security testing.",
        "Support DRY_RUN=1 mode printing curl command and signature headers without sending HTTP request.",
        "Create test suite scripts/eap/test_emit_eap_webhook.sh testing all CLI commands.",
        "Verify kurasi vector: emitting webhook for kurasi asserts response contains hash 6f82ad81 and mesh URL.",
        "Document CLI emitter usage, flags, and CI/CD integration patterns in docs/signalloom/slte-p3-emitter-cli.md."
    ],
    deliverables=[
        "Production-grade CLI tool in scripts/eap/emit-eap-webhook.sh supporting GitHub and generic webhook simulation.",
        "Automated HMAC-SHA256 signature calculation utility supporting openssl and python fallbacks.",
        "Tamper simulation command for negative security verification and penetration testing.",
        "Comprehensive test suite in scripts/eap/test_emit_eap_webhook.sh verifying all CLI subcommands.",
        "docs/signalloom/slte-p3-emitter-cli.md detailing CLI flags, environment variables, and CI runbooks.",
        "Append-only errata entry for SLTE-P3-2 in proposal markdown."
    ],
    tests=[
        "bash scripts/eap/test_emit_eap_webhook.sh",
        "pytest tests/test_webhook_triggers.py -v",
        "pytest tests/ -v"
    ],
    evidence=[
        "Captured test output showing 100% pass across CLI webhook emitter assertions.",
        "Execution trace of emit-eap-webhook.sh github-pr kurasi 42 opened returning HTTP 200.",
        "docs/signalloom/slte-p3-emitter-cli.md with complete CLI documentation.",
        "Errata block appended for SLTE-P3-2 with status=pass."
    ],
    failures=[
        "Failing to handle curl connection errors when target backend is offline.",
        "Generating malformed signature headers causing unexpected verification failures.",
        "Unquoted shell variables causing word splitting in JSON payload strings."
    ]
)

# P3-GOV: M governor (>=450w, >=35l, >=5d, tests exempt)
SPECS["P3-GOV"] = make_spec(
    "P3-GOV", "M", "governor",
    obj=(
        "Phase 3 Governor Certification: independently verify Envoy Ingress HTTPRoute manifests, webhook signature "
        "enforcement at the gateway boundary, and CLI emitter automation. Audit shell scripts using shellcheck to ensure "
        "zero warnings, verify that the synthetic emitter successfully drives end-to-end webhook processing, and confirm "
        "that tampered payloads are unconditionally rejected with HTTP 401. Reconcile Phase 3 deliverables into the "
        "integration branch, execute all test suites, author certification documentation, and certify readiness for "
        "Phase 4 end-to-end acceptance testing."
    ),
    approach=[
        "Review git diff of all Phase 3 scripts, manifests, and documentation.",
        "Execute scripts/eap/test_emit_eap_webhook.sh in full.",
        "Audit all shell scripts using shellcheck to confirm zero warnings or linting defects.",
        "Verify that tampered webhook emissions receive HTTP 401 without processing.",
        "Verify kanban board doctor status ensuring zero graph anomalies or orphaned worktrees.",
        "Author Phase 3 certification report in docs/signalloom/slte-p3-certification.md.",
        "Append qualified Phase 3 completion errata block to proposal markdown."
    ],
    deliverables=[
        "docs/signalloom/slte-p3-certification.md certifying Phase 3 Ingress and CLI emitter automation.",
        "Automated governor verification script executing end-to-end synthetic webhook test.",
        "Captured test output demonstrating 100% pass across all Phase 3 test suites.",
        "Clean kanban-check doctor verification report.",
        "Phase 3 Governor errata block appended to proposal markdown with status=pass."
    ],
    tests=[
        "bash scripts/eap/test_emit_eap_webhook.sh",
        "pytest tests/test_webhook_triggers.py -v",
        "~/.claude/skills/ajm-auto-kanban/Tools/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLTE"
    ],
    evidence=[
        "docs/signalloom/slte-p3-certification.md signed with verification artifacts.",
        "Green test run outputs demonstrating zero defects across shell automation suites.",
        "Clean doctor output verifying healthy board state.",
        "Errata block appended for SLTE-P3-GOV with status=pass."
    ],
    failures=[
        "Certifying Phase 3 while any shell script fails shellcheck compliance.",
        "Allowing unvalidated HTTPRoute manifests into the integration baseline.",
        "Failing to test negative tampering scenarios at the gateway boundary."
    ]
)

# P4-PRE: S preflight (>=250w, >=20l, >=4d, tests exempt)
SPECS["P4-PRE"] = make_spec(
    "P4-PRE", "S", "preflight",
    obj=(
        "Audit customer kurasi external trigger integration and GitHub Actions pipeline workflow definitions. "
        "Verify how external PR events will be simulated and validated in acceptance tests, check secret injection "
        "mechanisms for customer webhook tokens, and verify teardown triggers upon PR merge or closure before building "
        "the automated PR preview lifecycle engine."
    ),
    approach=[
        "Review kurasi GitHub Actions workflow template and webhook delivery payloads.",
        "Verify secret delivery mechanisms ensuring webhook secret is accessible to CI runner.",
        "Audit PR lifecycle state machine: opened -> preview online; sync -> preview updated; closed -> preview deleted.",
        "Verify cleanup guarantees ensuring orphaned PR previews are garbage collected after 24 hours.",
        "Draft preflight audit report in docs/signalloom/slte-p4-preflight.md with customer integration blueprint."
    ],
    deliverables=[
        "docs/signalloom/slte-p4-preflight.md detailing customer kurasi webhook integration blueprint.",
        "GitHub Actions workflow template for external PR preview triggers.",
        "Lifecycle state transition audit verifying clean teardown on PR close.",
        "Errata block appended for SLTE-P4-PRE in proposal markdown."
    ],
    tests=[
        "test -f docs/signalloom/slte-p4-preflight.md",
        "pytest tests/test_webhook_triggers.py -v",
        "git status --porcelain"
    ],
    evidence=[
        "docs/signalloom/slte-p4-preflight.md documenting all customer integration specifications.",
        "Captured test output showing clean preflight execution.",
        "Errata block appended for SLTE-P4-PRE with status=pass."
    ],
    failures=[
        "Assuming external CI runner has network access to internal tailnet without proxy or public webhook receiver.",
        "Failing to handle PR re-opening events leading to stale environment references.",
        "Omitting secret rotation procedures for webhook tokens."
    ]
)

# P4-1: L implementation (>=700w, >=50l, >=6d, >=5t)
SPECS["P4-1"] = make_spec(
    "P4-1", "L", "implementation",
    obj=(
        "Build the automated PR preview environment lifecycle controller in scripts/eap/eap-pr-preview-controller.sh "
        "and fe-signalloom/src/pr_preview_manager.py. Implement automated spin-up of preview environments keyed by "
        "pull request index: e.g. sl-eap-{hash}-pr{number}.tailscale. When a PR opened webhook arrives, automatically "
        "provision the preview environment, configure Tailscale mesh routing, register Envoy HTTPRoute, and post a "
        "synthetic PR comment payload containing the live preview URL. When PR commits are synchronized, automatically "
        "extend the TTL and trigger hot reload. When the PR is closed or merged, immediately trigger graceful teardown, "
        "de-register the route, and log out the ephemeral node. Write comprehensive unit and integration tests."
    ),
    approach=[
        "Create scripts/eap/eap-pr-preview-controller.sh with commands: on-pr-open, on-pr-sync, on-pr-close.",
        "Implement fe-signalloom/src/pr_preview_manager.py with PRPreviewManager class.",
        "In on-pr-open, derive customer hash (e.g. kurasi -> 6f82ad81) and format preview hostname sl-eap-6f82ad81-pr$PR.",
        "Call environment provisioning API to reserve preview environment with 120-minute lease.",
        "Generate PR comment payload with Markdown table containing preview URLs, credentials, and TTL expiration countdown.",
        "In on-pr-sync, extend TTL and signal deployment orchestrator to refresh preview container images.",
        "In on-pr-close, initiate graceful teardown, remove HTTPRoute, and clean up Tailscale serve configuration.",
        "Ensure all controller operations are fully idempotent.",
        "Write comprehensive test suite in fe-signalloom/src/tests/test_pr_preview_manager.py.",
        "Test PR open -> sync -> close lifecycle with mocked GitHub API responses.",
        "Document PR preview controller architecture and GitHub comment format in docs/signalloom/slte-p4-pr-controller.md."
    ],
    deliverables=[
        "PR preview lifecycle automation script in scripts/eap/eap-pr-preview-controller.sh.",
        "fe-signalloom/src/pr_preview_manager.py implementing PR preview orchestrator.",
        "Comprehensive test suite in fe-signalloom/src/tests/test_pr_preview_manager.py.",
        "GitHub PR Markdown comment formatting template with live preview URLs.",
        "Idempotent teardown and garbage collection automation for closed pull requests.",
        "docs/signalloom/slte-p4-pr-controller.md detailing PR preview architecture and operational runbooks.",
        "Append-only errata entry for SLTE-P4-1 in proposal markdown."
    ],
    tests=[
        "pytest tests/test_pr_preview_manager.py -v",
        "pytest tests/test_webhook_triggers.py -v",
        "pytest tests/ -v"
    ],
    evidence=[
        "Captured pytest execution log demonstrating 100% pass across PR preview controller test suite.",
        "Rendered PR comment transcript showing formatted Markdown preview URLs for kurasi PR #42.",
        "docs/signalloom/slte-p4-pr-controller.md with complete sequence diagrams.",
        "Errata block appended for SLTE-P4-1 with status=pass."
    ],
    failures=[
        "Failing to clean up preview environments when PR is closed without merging.",
        "Race condition between concurrent PR pushes causing multiple preview environments for same PR.",
        "Exceeding GitHub API rate limits when posting automated PR comments."
    ]
)

# P4-2: L implementation (>=700w, >=50l, >=6d, >=5t)
SPECS["P4-2"] = make_spec(
    "P4-2", "L", "implementation",
    obj=(
        "Build comprehensive end-to-end acceptance test suite for kurasi webhook trigger lifecycle in "
        "fe-signalloom/src/tests/test_kurasi_webhook_lifecycle.py. Simulate complete customer journey: external CI/CD runner "
        "emits signed GitHub webhook for PR #42 opened -> webhook router verifies HMAC-SHA256 signature -> environment engine "
        "provisions sl-eap-6f82ad81 -> router responds with 200 OK and mesh URL https://sl-eap-6f82ad81.tailscale -> external "
        "probe verifies environment is live and reachable -> CI runner emits PR synchronized event extending TTL -> CI runner "
        "emits PR closed event triggering immediate teardown -> post-teardown probe confirms environment is terminated and "
        "resources are clean. Verify 100% test stability across multiple consecutive test runs."
    ),
    approach=[
        "Create fe-signalloom/src/tests/test_kurasi_webhook_lifecycle.py with pytest-asyncio and FastAPI TestClient.",
        "Implement test_kurasi_webhook_end_to_end_journey executing sequential lifecycle stages.",
        "Stage 1 (Webhook Ingestion): Emit signed GitHub pull_request.opened event for repo 'kurasi-app'.",
        "Assert Stage 1: HTTP 200 OK, action_taken=='provisioned', customer_hash=='6f82ad81', hostname=='sl-eap-6f82ad81'.",
        "Stage 2 (Status Probe): GET /api/v1/environments/{id} asserting state is READY and TTL remaining > 0.",
        "Stage 3 (PR Sync): Emit signed pull_request.synchronize event; assert HTTP 200 OK and action_taken=='extended_ttl'.",
        "Stage 4 (PR Closed): Emit signed pull_request.closed event; assert HTTP 200 OK and action_taken=='torn_down'.",
        "Stage 5 (Post-Teardown Probe): Verify environment state is TERMINATED and resolve-domain reports is_active==False.",
        "Stage 6 (Negative Security): Emit tampered signature payload and assert HTTP 401 Unauthorized.",
        "Run test suite across 10 repeated iterations to verify absolute test stability and zero flakiness.",
        "Write acceptance report in docs/signalloom/slte-p4-acceptance-report.md documenting complete lifecycle run."
    ],
    deliverables=[
        "End-to-end acceptance test suite in fe-signalloom/src/tests/test_kurasi_webhook_lifecycle.py.",
        "Full lifecycle execution transcript capturing request and response bodies for every step.",
        "Negative security testing fixture asserting fail-closed behavior on tampered signatures.",
        "Idempotent teardown and resource cleanup verification test.",
        "docs/signalloom/slte-p4-acceptance-report.md detailing test results and verification logs.",
        "Append-only errata entry for SLTE-P4-2 in proposal markdown."
    ],
    tests=[
        "pytest tests/test_kurasi_webhook_lifecycle.py -v",
        "pytest tests/test_webhook_triggers.py -v",
        "pytest tests/test_environment_routing.py -v",
        "pytest tests/ -v"
    ],
    evidence=[
        "Captured pytest execution log demonstrating 100% pass on kurasi webhook acceptance suite.",
        "Full JSON trace of kurasi webhook-triggered environment lifecycle states.",
        "docs/signalloom/slte-p4-acceptance-report.md with complete test output citations.",
        "Errata block appended for SLTE-P4-2 with status=pass."
    ],
    failures=[
        "Flaky async test timing during webhook event processing assertions.",
        "Failing to clean up temporary test database entries leaving stale state between test runs.",
        "Failing to assert exact match on canonical hash 6f82ad81 in webhook responses."
    ]
)

# P4-GOV: L governor (>=700w, >=50l, >=6d, tests exempt)
SPECS["P4-GOV"] = make_spec(
    "P4-GOV", "L", "governor",
    obj=(
        "Final Mission Certification for SLTE: execute comprehensive independent verification of the entire external "
        "webhook ingestion and trigger engine, HMAC-SHA256 signature verifiers, replay attack defense, and customer 'kurasi' "
        "lifecycle automation. Audit code quality, test coverage, documentation completeness, API wire contracts, and "
        "architectural compliance across the entire monorepo. Confirm that 100% of tests pass across all Python, shell, and "
        "acceptance suites with zero regressions. Verify that the kanban board doctor check passes with zero defects. "
        "Author the final mission certification report in docs/signalloom/slte-mission-complete.md, append the final mission "
        "certification errata block, and seal the SLTE release for production deployment."
    ),
    approach=[
        "Checkout integration branch integration/slte-v0.1.0 or inspect clean git status.",
        "Execute full test suite in fe-signalloom: unit tests, webhook tests, environment tests, and acceptance tests.",
        "Execute kurasi webhook acceptance suite in test_kurasi_webhook_lifecycle.py asserting 100% green status.",
        "Execute shell test suites: test_emit_eap_webhook.sh and test_tailscale_eap_env.sh.",
        "Audit docs/ to confirm all required documentation files exist, are well-linked, and contain no broken references.",
        "Run scripts/kanban-check.sh doctor --shortcode SLTE to confirm zero unresolved defects or orphaned cards.",
        "Verify that kurasi canonical hash is strictly 6f82ad81 and mesh URL is https://sl-eap-6f82ad81.tailscale.",
        "Author final mission certification document in docs/signalloom/slte-mission-complete.md.",
        "Append final Phase 4 Governor errata block to proposal markdown marking SLTE mission fully certified."
    ],
    deliverables=[
        "Final mission certification document in docs/signalloom/slte-mission-complete.md.",
        "Comprehensive green test execution transcript covering Python, shell, and acceptance test suites.",
        "Clean kanban-check doctor verification report proving zero board anomalies.",
        "Final errata block appended to proposal markdown marking Phase 4 certified.",
        "Release readiness checklist verifying all acceptance criteria have been satisfied.",
        "Final integration branch merge commit sealing the SLTE v0.1.0 release.",
        "docs/signalloom/slte-architecture-summary.md summarizing the new webhook trigger capabilities."
    ],
    tests=[
        "pytest tests/test_kurasi_webhook_lifecycle.py -v",
        "pytest tests/test_webhook_triggers.py tests/test_environment_routing.py -v",
        "bash scripts/eap/test_tailscale_eap_env.sh",
        "~/.claude/skills/ajm-auto-kanban/Tools/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLTE"
    ],
    evidence=[
        "docs/signalloom/slte-mission-complete.md detailing full mission certification.",
        "Captured test logs demonstrating 100% green status across all suites.",
        "Clean doctor output verifying zero defects.",
        "Final errata block appended for SLTE-P4-GOV with status=pass."
    ],
    failures=[
        "Declaring mission complete while any acceptance test is mocked rather than fully executed.",
        "Leaving uncommitted temporary files or dirty git worktree state.",
        "Failing to certify canonical kurasi vector across all operational layers.",
        "Overlooking broken links or incomplete documentation in docs/signalloom/."
    ]
)

def main():
    print("Validating and generating council-grade card specifications for SLTE...\n")
    all_ok = True
    for lid, card_spec in SPECS.items():
        band = "S"
        role = "implementation"
        if "PRE" in lid:
            band = "S"
            role = "preflight"
        elif "GOV" in lid:
            role = "governor"
            band = "L" if lid == "P4-GOV" else "M"
        elif lid == "P0":
            band = "S"
            role = "implementation"
        elif lid in ("P1-1", "P1-2"):
            band = "M"
            role = "implementation"
        elif lid in ("P2-1", "P2-2", "P3-1", "P3-2", "P4-1", "P4-2"):
            band = "L"
            role = "implementation"

        m = pc.spec_metrics(card_spec)
        req_words, req_lines, req_deliv, req_tests = pc.SPEC_FLOORS[band]
        if role in pc.TEST_FLOOR_EXEMPT_ROLES:
            req_tests = 0

        ok = (m["words"] >= req_words and m["lines"] >= req_lines and
              m["deliverables"] >= req_deliv and m["tests"] >= req_tests and
              m["distinctLineRatio"] >= pc.MIN_DISTINCT_LINE_RATIO)

        status = "PASS" if ok else "FAIL"
        if not ok:
            all_ok = False
            shortfalls = []
            if m["words"] < req_words: shortfalls.append(f"words {m['words']} < {req_words}")
            if m["lines"] < req_lines: shortfalls.append(f"lines {m['lines']} < {req_lines}")
            if m["deliverables"] < req_deliv: shortfalls.append(f"deliv {m['deliverables']} < {req_deliv}")
            if m["tests"] < req_tests: shortfalls.append(f"tests {m['tests']} < {req_tests}")
            if m["distinctLineRatio"] < pc.MIN_DISTINCT_LINE_RATIO: shortfalls.append(f"ratio {m['distinctLineRatio']} < {pc.MIN_DISTINCT_LINE_RATIO}")
            print(f"[{status}] {lid} ({band} {role}): {'; '.join(shortfalls)}")
        else:
            print(f"[{status}] {lid} ({band} {role}): {m['words']}w, {m['lines']}l, {m['deliverables']}d, {m['tests']}t, {m['distinctLineRatio']}r")

        # Write out to card-specs/SLTE/<ID>.v1.json
        card_spec = cc.apply_card_contract(card_spec, repo_root=cc.REPO_ROOT)
        spec_payload = {
            "specCacheVersion": 1,
            "shortcode": "SLTE",
            "logicalId": lid,
            "proposalContractSha256": CONTRACT_SHA,
            "cachedAt": "2026-09-17T20:00:00Z",
            "cardSpecification": card_spec
        }
        out_file = SPEC_DIR / f"{lid}.v1.json"
        out_file.write_text(json.dumps(spec_payload, indent=2))

    if not all_ok:
        print("\nERROR: Some specifications failed floor validation!")
        sys.exit(1)

    print(f"\nSUCCESS: All {len(SPECS)} SLTE card specifications generated and 100% compliant with SPEC_FLOORS!")

if __name__ == "__main__":
    main()
