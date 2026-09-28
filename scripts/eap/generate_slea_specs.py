#!/usr/bin/env python3
"""Generates council-grade card specifications for the SLEA mission.

Produces ~/.cline/kanban/card-specs/SLEA/<ID>.v1.json for all 17 cards,
meeting and exceeding all word, line, deliverable, and test-surface floors.
"""
from __future__ import annotations

import json
import os
import importlib.util
from pathlib import Path

# EAPR-P1-3: shared card contract — filename-collision refusal and the D1
# Authorization wire spec carried into every generated card.
_cc_spec = importlib.util.spec_from_file_location(
    "_card_contract", str(Path(__file__).resolve().parent / "_card_contract.py"))
cc = importlib.util.module_from_spec(_cc_spec)
_cc_spec.loader.exec_module(cc)

SPEC_DIR = Path.home() / ".cline" / "kanban" / "card-specs" / "SLEA"
SPEC_DIR.mkdir(parents=True, exist_ok=True)

SHARED_KEY_FACTS = [
    "Repository root is /home/andy/src/cp/osramp-demo.",
    "Integration branch is feat/signal-loop-and-bootstrap-refactor.",
    "First customer company name is 'kusari', canonical salt is 'test-eap-salt-2026', yielding hash 'a0314bec'.",
    "Tailscale internal mesh URL format is https://sl-eap-a0314bec.tailscale and MagicDNS FQDN is https://sl-eap-a0314bec.ts.net.",
    "Backend FastAPI application lives in d2-signalloom/apps/fe-signalloom/src/ with test suite in tests/.",
    "Dex OIDC callback origin leasing must be claimed via dex_origin apply tailscale <origin> to avoid login bounce failures.",
    "Tailscale Serve and Funnel automation requires --accept-dns=false and idempotent logout/reset on de-provisioning."
]

SHARED_STOP_AND_REPORT = [
    "Discovery that Tailscale CLI or operator cannot run or configure subdomains without root permissions.",
    "Any condition where Dex OIDC redirect URI rejects dynamic https://sl-eap-HASH.tailscale callbacks.",
    "Any leak of unhashed customer company names or proprietary code into telemetry payloads or public logs.",
    "Non-idempotent provisioning or teardown actions leaving orphaned namespaces or zombie Tailscale nodes."
]

SHARED_OUT_OF_SCOPE = [
    "Modifying existing SLER enforcement kernel modules or eBPF programs.",
    "Modifying SLDP OpenBao Transit key derivation or KMS encryption primitives.",
    "Ingesting customer proprietary code, prompt text, or completion tokens.",
    "Hardcoding cloud credentials in git-tracked manifest files."
]

SPECS = {
    "P0": {
        "logicalId": "P0",
        "objective": (
            "Establish and verify the initial environment routing baseline, Tailscale CLI fixtures, "
            "and Python test harness for the SLEA mission. Verify that the repository is clean, "
            "that d2-signalloom/apps/fe-signalloom/src test suite executes cleanly under pytest, and "
            "that the kanban-check doctor passes with zero anomalies before any environment routing "
            "or dynamic provisioning code is introduced."
        ),
        "approach": [
            "Run scripts/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLEA to capture baseline state.",
            "Inspect d2-signalloom/apps/fe-signalloom/src/main.py to inventory all installed API routers and lifecycle hooks.",
            "Run pytest on fe-signalloom/src/tests to confirm baseline passing state across existing suites.",
            "Verify Tailscale mock harness and environment variables (SIGNAL_LOOM_EAP_SALT, TAILSCALE_AUTH_KEY).",
            "Document baseline findings, installed packages, and test coverage in docs/signalloom/slea-p0-baseline.md."
        ],
        "deliverables": [
            "docs/signalloom/slea-p0-baseline.md recording harness identity, existing router inventory, and test baseline.",
            "Clean test run output from fe-signalloom test suite attached as baseline evidence.",
            "Baseline doctor check output proving zero uncompiled cards or broken dependencies.",
            "Initial test harness fixture in tests/test_environment_routing.py asserting test harness readiness."
        ],
        "testSurface": [
            "pytest tests/test_environment_routing.py -v",
            "~/.claude/skills/ajm-auto-kanban/Tools/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLEA",
            "test -f docs/signalloom/slea-p0-baseline.md",
            "pytest tests/test_coding_agent_telemetry.py"
        ],
        "evidence": [
            "docs/signalloom/slea-p0-baseline.md with citations of all inspected router files.",
            "Captured pytest execution log demonstrating 100% pass on baseline fixtures.",
            "Captured kanban-check doctor output with clean status.",
            "Errata block appended for SLEA-P0 with status=pass."
        ],
        "failureModes": [
            "Assuming Tailscale binary is installed in default PATH without fallback or mock mode for local unit tests.",
            "Assuming fe-signalloom uses a global virtualenv rather than local python3 / pytest runtime.",
            "Failing to capture existing router list leading to duplicate prefix collisions."
        ],
        "stopAndReport": SHARED_STOP_AND_REPORT,
        "loopOn": [
            "pytest tests/test_environment_routing.py",
            "test -f docs/signalloom/slea-p0-baseline.md"
        ],
        "outOfScope": SHARED_OUT_OF_SCOPE,
        "sharedFileRisks": [
            "d2-signalloom/apps/fe-signalloom/src/main.py — multiple router installations; coordinate through governor.",
            "Proposal Errata section — append-only qualified blocks."
        ],
        "consumesFromEarlierPhases": ["None. This card is the foundational baseline for the SLEA mission."],
        "mergeBoundary": "SLEA-P0 commits to task worktree and merges to integration branch via Phase 1 Preflight.",
        "keyFacts": SHARED_KEY_FACTS
    },
    "P1-PRE": {
        "logicalId": "P1-PRE",
        "objective": (
            "Audit customer hashing salt, DNS label constraints, and Tailscale MagicDNS contracts. "
            "Verify RFC 1123 compliance for generated sl-eap-HASH subdomains, confirm the canonical test vector "
            "for initial customer 'kusari', and verify that the proposed cryptographic salt structure prevents "
            "both rainbow table inversion and domain collisions."
        ),
        "approach": [
            "Review RFC 1123 and Tailscale MagicDNS requirements: max 63 chars per DNS label, lowercase alphanumeric and hyphens only.",
            "Validate that canonical company name 'kusari' with salt 'test-eap-salt-2026' hashes deterministically to 'a0314bec'.",
            "Verify that 'sl-eap-a0314bec' is exactly 15 characters, well within the 63-character DNS label limit.",
            "Inspect Python hashlib and hmac modules to choose optimal, zero-dependency hashing implementation.",
            "Document DNS specifications, collision probability analysis, and salt rotation strategy in docs/signalloom/slea-p1-pre-audit.md."
        ],
        "deliverables": [
            "docs/signalloom/slea-p1-pre-audit.md documenting DNS label constraints and cryptographic salt analysis.",
            "Test matrix of 20 sample customer company names and their deterministic 8-character hex digests.",
            "Verification script proving RFC 1123 regex match on all generated hostnames.",
            "Recorded preflight checklist proving readiness for Phase 1 implementation."
        ],
        "testSurface": [
            "python3 -c 'import re; assert re.match(r\"^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$\", \"sl-eap-a0314bec\")'",
            "test -f docs/signalloom/slea-p1-pre-audit.md",
            "~/.claude/skills/ajm-auto-kanban/Tools/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLEA"
        ],
        "evidence": [
            "docs/signalloom/slea-p1-pre-audit.md detailing RFC 1123 compliance and collision probability.",
            "Captured execution of test matrix confirming zero hash collisions across sample space.",
            "Errata block appended for SLEA-P1-PRE with status=pass."
        ],
        "failureModes": [
            "Allowing uppercase characters or underscores in DNS labels causing Tailscale or Envoy ingress routing errors.",
            "Using unsalted hashes allowing third parties to invert customer company identities via rainbow tables.",
            "Truncating hashes to fewer than 8 hex characters, drastically increasing birthday collision risk."
        ],
        "stopAndReport": SHARED_STOP_AND_REPORT,
        "loopOn": [
            "test -f docs/signalloom/slea-p1-pre-audit.md"
        ],
        "outOfScope": SHARED_OUT_OF_SCOPE,
        "sharedFileRisks": [
            "Proposal Errata section — append-only qualified blocks."
        ],
        "consumesFromEarlierPhases": ["SLEA-P0 baseline confirmation."],
        "mergeBoundary": "SLEA-P1-PRE commits to task worktree and merges to integration branch via Phase 1 Governor.",
        "keyFacts": SHARED_KEY_FACTS
    },
    "P1-1": {
        "logicalId": "P1-1",
        "objective": (
            "Implement the core cryptographic salt hashing and sl-eap-HASH.tailscale URL generator module "
            "in d2-signalloom/apps/fe-signalloom/src/environment_routing.py. The module must normalize company names "
            "via lowercase and whitespace stripping, compute HMAC-SHA256 or salted SHA-256 digests, format valid RFC 1123 "
            "hostnames, and produce both internal tailnet mesh URLs and MagicDNS FQDNs with 100% test coverage."
        ),
        "approach": [
            "Create d2-signalloom/apps/fe-signalloom/src/environment_routing.py containing derive_customer_hash and build_environment_urls.",
            "Implement normalization: name.strip().lower() to ensure whitespace and casing variations yield identical hashes.",
            "Implement configurable salt support reading SIGNAL_LOOM_EAP_SALT with fallback to 'test-eap-salt-2026'.",
            "Format hostnames as sl-eap-{hash} and URLs as https://sl-eap-{hash}.tailscale and https://sl-eap-{hash}.{tailnet}.ts.net.",
            "Write comprehensive unit tests in tests/test_environment_routing.py verifying kusari test vector and edge cases."
        ],
        "deliverables": [
            "d2-signalloom/apps/fe-signalloom/src/environment_routing.py with derive_customer_hash and build_environment_urls functions.",
            "Comprehensive unit test suite in tests/test_environment_routing.py asserting test vectors and error boundaries.",
            "Validation of 'kusari' yielding exactly 'a0314bec' and hostname 'sl-eap-a0314bec'.",
            "Type hints and docstrings following PEP 484 and Google Python style guide.",
            "Clean pytest run with zero failures or regressions."
        ],
        "testSurface": [
            "pytest tests/test_environment_routing.py -k 'test_derive_customer_hash' -v",
            "pytest tests/test_environment_routing.py -k 'test_build_environment_urls' -v",
            "pytest tests/test_environment_routing.py -k 'test_kusari_canonical_vector' -v",
            "pytest tests/test_environment_routing.py -v"
        ],
        "evidence": [
            "Captured pytest log showing 100% pass on hashing and URL generation test cases.",
            "Code snippet demonstrating derive_customer_hash implementation.",
            "Errata block appended for SLEA-P1-1 with status=pass."
        ],
        "failureModes": [
            "Failing to strip leading/trailing whitespace resulting in different hashes for 'kusari' vs ' kusari '.",
            "Case sensitivity bugs where 'Kusari' produces a different hash than 'kusari'.",
            "Hardcoding the salt string directly in code without environment variable override capability."
        ],
        "stopAndReport": SHARED_STOP_AND_REPORT,
        "loopOn": [
            "pytest tests/test_environment_routing.py -v"
        ],
        "outOfScope": SHARED_OUT_OF_SCOPE,
        "sharedFileRisks": [
            "d2-signalloom/apps/fe-signalloom/src/environment_routing.py — owned by P1-1 and P1-2.",
            "Proposal Errata section — append-only qualified blocks."
        ],
        "consumesFromEarlierPhases": ["SLEA-P1-PRE preflight audit."],
        "mergeBoundary": "SLEA-P1-1 commits to task worktree and merges to integration branch via SLEA-P1-GOV.",
        "keyFacts": SHARED_KEY_FACTS
    },
    "P1-2": {
        "logicalId": "P1-2",
        "objective": (
            "Define the environment provisioning data models, schema validations, and state machines "
            "in d2-signalloom/apps/fe-signalloom/src/environment_routing.py using Pydantic v2. Models must include "
            "ProvisionRequest, EnvironmentResponse, EnvironmentState, TeardownRequest, and ResolveDomainResponse, "
            "enforcing strict field validations, TTL boundaries (1 to 168 hours), and environment statuses."
        ),
        "approach": [
            "Define EnvironmentStatus enum: PROVISIONING, READY, SUSPENDED, TORN_DOWN, EXPIRED.",
            "Define EnvironmentType enum: DEMO, UAT, PROD_TRIAL.",
            "Implement ProvisionRequest model validating customer_name (min 2, max 64 chars), ttl_hours (1..168), and features list.",
            "Implement EnvironmentResponse model containing environment_id, hostname, url, tailnet_fqdn, dex_issuer, and expires_at.",
            "Implement in-memory EnvironmentRegistry store with thread-safe storage and status lookup methods.",
            "Add schema validation unit tests in tests/test_environment_routing.py."
        ],
        "deliverables": [
            "Pydantic schema definitions in d2-signalloom/apps/fe-signalloom/src/environment_routing.py.",
            "EnvironmentStatus and EnvironmentType enumeration classes.",
            "EnvironmentRegistry storage abstraction with provision, get, list, and teardown methods.",
            "Unit tests in tests/test_environment_routing.py validating field constraints and TTL boundaries.",
            "Clean pytest run verifying model serialization and JSON-schema export."
        ],
        "testSurface": [
            "pytest tests/test_environment_routing.py -k 'test_provision_request_validation' -v",
            "pytest tests/test_environment_routing.py -k 'test_environment_response_serialization' -v",
            "pytest tests/test_environment_routing.py -k 'test_registry_state_machine' -v",
            "pytest tests/test_environment_routing.py -v"
        ],
        "evidence": [
            "Captured pytest log verifying all Pydantic model validation and state machine tests pass.",
            "JSON schema dump of EnvironmentResponse showing exact wire contract format.",
            "Errata block appended for SLEA-P1-2 with status=pass."
        ],
        "failureModes": [
            "Allowing ttl_hours <= 0 or > 168 hours, risking perpetual orphaned cloud resources.",
            "Permitting empty or invalid customer company names without alphanumeric characters.",
            "Incompatible datetime serialization between Python isoformat and JavaScript Date parsers."
        ],
        "stopAndReport": SHARED_STOP_AND_REPORT,
        "loopOn": [
            "pytest tests/test_environment_routing.py -v"
        ],
        "outOfScope": SHARED_OUT_OF_SCOPE,
        "sharedFileRisks": [
            "d2-signalloom/apps/fe-signalloom/src/environment_routing.py — shared with P1-1; merge via P1-GOV.",
            "Proposal Errata section — append-only qualified blocks."
        ],
        "consumesFromEarlierPhases": ["SLEA-P1-1 hashing and URL generator."],
        "mergeBoundary": "SLEA-P1-2 commits to task worktree and merges to integration branch via SLEA-P1-GOV.",
        "keyFacts": SHARED_KEY_FACTS
    },
    "P1-GOV": {
        "logicalId": "P1-GOV",
        "objective": (
            "Certify Phase 1 deliverables: verify that hashing vectors (specifically the 'kusari' check) "
            "and domain generation contracts meet all enterprise requirements with zero regressions. Audit code "
            "quality, type coverage, and test suites across P1-1 and P1-2, proving that 100 random customer inputs "
            "generate valid RFC 1123 hostnames without collisions."
        ),
        "approach": [
            "Execute full test suite in d2-signalloom/apps/fe-signalloom/src/tests/test_environment_routing.py.",
            "Run randomized fuzzing test with 1,000 distinct company names to mathematically verify zero collisions.",
            "Verify that 'kusari' strictly outputs hash 'a0314bec' and hostname 'sl-eap-a0314bec'.",
            "Check that all Pydantic models reject invalid inputs and serialize valid ISO-8601 timestamps.",
            "Run scripts/kanban-check.sh doctor to ensure repo health and append certified errata block."
        ],
        "deliverables": [
            "Certified Phase 1 test report attached to docs/signalloom/slea-p1-gov-certification.md.",
            "Fuzzing test script verifying 1,000 unique company names generate 1,000 unique RFC 1123 hostnames.",
            "Captured clean execution of all fe-signalloom pytest suites.",
            "Verified kanban doctor report confirming Phase 1 completion."
        ],
        "testSurface": [
            "pytest tests/test_environment_routing.py -v",
            "python3 -c 'from environment_routing import derive_customer_hash; assert derive_customer_hash(\"kusari\") == \"a0314bec\"'",
            "~/.claude/skills/ajm-auto-kanban/Tools/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLEA"
        ],
        "evidence": [
            "docs/signalloom/slea-p1-gov-certification.md recording Phase 1 certification facts.",
            "Captured pytest log showing 100% pass across all Phase 1 test cases.",
            "Errata block appended for SLEA-P1-GOV with status=pass."
        ],
        "failureModes": [
            "Overlooking subtle case normalization regressions between different operating systems.",
            "Failing to assert that the canonical customer 'kusari' produces exact hash 'a0314bec'."
        ],
        "stopAndReport": SHARED_STOP_AND_REPORT,
        "loopOn": [
            "pytest tests/test_environment_routing.py -v"
        ],
        "outOfScope": SHARED_OUT_OF_SCOPE,
        "sharedFileRisks": [
            "Proposal Errata section — append-only qualified blocks."
        ],
        "consumesFromEarlierPhases": ["SLEA-P1-1 and SLEA-P1-2 outputs."],
        "mergeBoundary": "SLEA-P1-GOV merges Phase 1 feature branch into integration line.",
        "keyFacts": SHARED_KEY_FACTS
    },
    "P2-PRE": {
        "logicalId": "P2-PRE",
        "objective": (
            "Audit FastAPI router seams and Dex OIDC origin lease hooks prior to Phase 2 API implementation. "
            "Verify how router prefixes are mounted in d2-signalloom/apps/fe-signalloom/src/main.py, inspect "
            "dependency injection for database connection pools, and determine the exact Dex origin lease "
            "claiming interface to prevent OAuth login bounces on dynamic domains."
        ),
        "approach": [
            "Inspect main.py to understand how existing routers (api_compat, audit_ingest, coding_agent_telemetry) install.",
            "Determine the target mount prefix for environment routing: /api/v1/environments.",
            "Inspect scripts/gcp-tf/demo-up.sh dex_origin implementation to understand the required lease payload format.",
            "Confirm authentication and role check patterns (Operator / Superadmin headers).",
            "Document findings and installation blueprint in docs/signalloom/slea-p2-pre-audit.md."
        ],
        "deliverables": [
            "docs/signalloom/slea-p2-pre-audit.md detailing router mount strategy and Dex origin mechanics.",
            "Route prefix conflict check proving /api/v1/environments does not overlap with existing endpoints.",
            "Mock Dex origin lease interface specification for unit test isolation.",
            "Preflight checklist approving Phase 2 API implementation kickoff."
        ],
        "testSurface": [
            "test -f docs/signalloom/slea-p2-pre-audit.md",
            "pytest tests/test_coding_agent_telemetry.py",
            "~/.claude/skills/ajm-auto-kanban/Tools/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLEA"
        ],
        "evidence": [
            "docs/signalloom/slea-p2-pre-audit.md with exact route table citations.",
            "Route collision check results attached as evidence.",
            "Errata block appended for SLEA-P2-PRE with status=pass."
        ],
        "failureModes": [
            "Mounting under a prefix that conflicts with api_compat or fe-signalloom reverse proxy rules.",
            "Omitting Dex origin lease coordination causing authentication redirect bounce on customer access."
        ],
        "stopAndReport": SHARED_STOP_AND_REPORT,
        "loopOn": [
            "test -f docs/signalloom/slea-p2-pre-audit.md"
        ],
        "outOfScope": SHARED_OUT_OF_SCOPE,
        "sharedFileRisks": [
            "Proposal Errata section — append-only qualified blocks."
        ],
        "consumesFromEarlierPhases": ["SLEA-P1-GOV certified hashing and models."],
        "mergeBoundary": "SLEA-P2-PRE commits to task worktree and merges via Phase 2 Governor.",
        "keyFacts": SHARED_KEY_FACTS
    },
    "P2-1": {
        "logicalId": "P2-1",
        "objective": (
            "Implement the core environment provisioning and domain resolution REST endpoints: "
            "POST /api/v1/environments/provision and POST /api/v1/environments/resolve-domain. "
            "Install the router in d2-signalloom/apps/fe-signalloom/src/main.py via install_environment_routing_api(app), "
            "supporting authenticated requests, idempotent re-provisioning, and returning full 201 Created and 200 OK responses."
        ),
        "approach": [
            "Create APIRouter with prefix '/api/v1/environments' in environment_routing.py.",
            "Implement POST /provision: validates ProvisionRequest, computes salted customer hash, registers environment state, returns EnvironmentResponse with HTTP 201.",
            "Implement POST /resolve-domain: lightweight utility taking company_name and returning calculated hash, hostname, and URL with HTTP 200.",
            "Wire install_environment_routing_api(app) into main.py.",
            "Write comprehensive FastAPI TestClient test cases covering successful provisioning, idempotence, and error validations."
        ],
        "deliverables": [
            "POST /api/v1/environments/provision endpoint returning full EnvironmentResponse schema.",
            "POST /api/v1/environments/resolve-domain endpoint for pre-flight URL resolution.",
            "Router installation in d2-signalloom/apps/fe-signalloom/src/main.py.",
            "Automated integration tests in tests/test_environment_routing.py using starlette/fastapi TestClient.",
            "Idempotency test confirming re-provisioning kusari returns existing record without duplicating ID."
        ],
        "testSurface": [
            "pytest tests/test_environment_routing.py -k 'test_api_provision_endpoint' -v",
            "pytest tests/test_environment_routing.py -k 'test_api_resolve_domain_endpoint' -v",
            "pytest tests/test_environment_routing.py -k 'test_api_provision_idempotency' -v",
            "pytest tests/test_environment_routing.py -v"
        ],
        "evidence": [
            "Captured pytest log verifying HTTP 201 and 200 responses on provision and resolve-domain.",
            "curl verification transcript against FastAPI TestClient.",
            "Errata block appended for SLEA-P2-1 with status=pass."
        ],
        "failureModes": [
            "Returning HTTP 200 instead of HTTP 201 Created on initial environment provisioning.",
            "Duplicating environment records when the same customer requests provisioning multiple times.",
            "Missing error handling for malformed JSON bodies or missing required fields."
        ],
        "stopAndReport": SHARED_STOP_AND_REPORT,
        "loopOn": [
            "pytest tests/test_environment_routing.py -v"
        ],
        "outOfScope": SHARED_OUT_OF_SCOPE,
        "sharedFileRisks": [
            "d2-signalloom/apps/fe-signalloom/src/main.py — shared installation point; serialise via governor.",
            "Proposal Errata section — append-only qualified blocks."
        ],
        "consumesFromEarlierPhases": ["SLEA-P2-PRE router seam audit."],
        "mergeBoundary": "SLEA-P2-1 commits to task worktree and merges via SLEA-P2-GOV.",
        "keyFacts": SHARED_KEY_FACTS
    },
    "P2-2": {
        "logicalId": "P2-2",
        "objective": (
            "Implement the environment lifecycle endpoints: GET /api/v1/environments (list), "
            "GET /api/v1/environments/{id} (get details), POST /api/v1/environments/{id}/extend (extend lease), "
            "and POST /api/v1/environments/{id}/teardown (deprovision). Include TTL countdown calculations, "
            "status filtering, and safe 404 Not Found error responses."
        ),
        "approach": [
            "Implement GET /api/v1/environments: supports query filtering by status and customer_name, returns list of environments.",
            "Implement GET /api/v1/environments/{id}: returns detailed state, active slices, and live TTL remaining.",
            "Implement POST /api/v1/environments/{id}/extend: extends expires_at by requested additional_hours (capped at 168h total).",
            "Implement POST /api/v1/environments/{id}/teardown: transitions state to TORN_DOWN, records deprovisioning timestamp.",
            "Add exhaustive TestClient tests for lifecycle workflows in tests/test_environment_routing.py."
        ],
        "deliverables": [
            "GET /api/v1/environments list endpoint with status query filter.",
            "GET /api/v1/environments/{id} detail endpoint.",
            "POST /api/v1/environments/{id}/extend TTL extension endpoint.",
            "POST /api/v1/environments/{id}/teardown deprovisioning endpoint.",
            "Comprehensive test cases in tests/test_environment_routing.py asserting all lifecycle transitions."
        ],
        "testSurface": [
            "pytest tests/test_environment_routing.py -k 'test_api_list_environments' -v",
            "pytest tests/test_environment_routing.py -k 'test_api_get_environment_detail' -v",
            "pytest tests/test_environment_routing.py -k 'test_api_extend_ttl' -v",
            "pytest tests/test_environment_routing.py -k 'test_api_teardown' -v",
            "pytest tests/test_environment_routing.py -v"
        ],
        "evidence": [
            "Captured pytest log verifying full lifecycle test coverage.",
            "HTTP response transcripts for list, get, extend, and teardown calls.",
            "Errata block appended for SLEA-P2-2 with status=pass."
        ],
        "failureModes": [
            "Allowing TTL extension beyond the maximum allowable 168-hour cap.",
            "Permitting operations on already torn down environments without returning proper 400/404 errors.",
            "Race conditions during concurrent teardown requests."
        ],
        "stopAndReport": SHARED_STOP_AND_REPORT,
        "loopOn": [
            "pytest tests/test_environment_routing.py -v"
        ],
        "outOfScope": SHARED_OUT_OF_SCOPE,
        "sharedFileRisks": [
            "d2-signalloom/apps/fe-signalloom/src/environment_routing.py — shared with P2-1.",
            "Proposal Errata section — append-only qualified blocks."
        ],
        "consumesFromEarlierPhases": ["SLEA-P2-1 provision endpoint."],
        "mergeBoundary": "SLEA-P2-2 commits to task worktree and merges via SLEA-P2-GOV.",
        "keyFacts": SHARED_KEY_FACTS
    },
    "P2-GOV": {
        "logicalId": "P2-GOV",
        "objective": (
            "Certify Phase 2 deliverables: verify the complete REST API contract for environment provisioning, "
            "TTL extensions, domain resolution, and teardown under both happy path and adversarial conditions. "
            "Audit OpenAPI schema generation, verify zero regressions across all fe-signalloom tests, and confirm "
            "that the kusari EAP environment endpoint responds according to specification."
        ),
        "approach": [
            "Run full pytest suite on fe-signalloom/src/tests/test_environment_routing.py.",
            "Verify OpenAPI specification (/openapi.json) includes all /api/v1/environments routes and schemas.",
            "Run negative tests: invalid customer names, out-of-range TTLs, non-existent environment IDs.",
            "Verify that kusari provisioning returns HTTP 201 with hostname 'sl-eap-a0314bec' and URL 'https://sl-eap-a0314bec.tailscale'.",
            "Run scripts/kanban-check.sh doctor and append certified errata block."
        ],
        "deliverables": [
            "Phase 2 API certification report attached to docs/signalloom/slea-p2-gov-certification.md.",
            "Verified OpenAPI schema dump containing environment routing paths.",
            "Captured 100% clean pass across all fe-signalloom tests.",
            "Certified errata block in proposal."
        ],
        "testSurface": [
            "pytest tests/test_environment_routing.py -v",
            "pytest tests/ -v",
            "~/.claude/skills/ajm-auto-kanban/Tools/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLEA"
        ],
        "evidence": [
            "docs/signalloom/slea-p2-gov-certification.md recording API certification evidence.",
            "OpenAPI path inspection proving presence of all 5 endpoints.",
            "Errata block appended for SLEA-P2-GOV with status=pass."
        ],
        "failureModes": [
            "Schema mismatches between Pydantic response models and OpenAPI JSON export.",
            "Leaking sensitive internal configuration or salts in API error bodies."
        ],
        "stopAndReport": SHARED_STOP_AND_REPORT,
        "loopOn": [
            "pytest tests/test_environment_routing.py -v"
        ],
        "outOfScope": SHARED_OUT_OF_SCOPE,
        "sharedFileRisks": [
            "Proposal Errata section — append-only qualified blocks."
        ],
        "consumesFromEarlierPhases": ["SLEA-P2-1 and SLEA-P2-2 outputs."],
        "mergeBoundary": "SLEA-P2-GOV merges Phase 2 feature branch into integration line.",
        "keyFacts": SHARED_KEY_FACTS
    },
    "P3-PRE": {
        "logicalId": "P3-PRE",
        "objective": (
            "Audit Tailscale Serve/Funnel automation scripts and Envoy Gateway API HTTPRoute seams prior "
            "to network mesh integration. Verify how Tailscale nodes are registered on Linux hosts, confirm "
            "Envoy HTTPRoute manifest structures in d2-infra/components/ingress/, and document the CLI "
            "interface needed to drive on-demand environment routing."
        ),
        "approach": [
            "Inspect scripts/gcp-tf/demo-up.sh cmd_ts_up and cmd_funnel_up to understand existing Tailscale automation patterns.",
            "Inspect d2-infra/components/ingress/ manifests to inventory Gateway API HTTPRoute configurations.",
            "Design the standalone script interface for scripts/eap/tailscale-eap-env.sh (hash, provision, status, teardown).",
            "Verify Tailscale mock execution mode for environments without a live tailnet connection.",
            "Document findings in docs/signalloom/slea-p3-pre-audit.md."
        ],
        "deliverables": [
            "docs/signalloom/slea-p3-pre-audit.md documenting Tailscale CLI contracts and Envoy Gateway seams.",
            "Specification for scripts/eap/tailscale-eap-env.sh subcommands and flag parameters.",
            "Sample Envoy HTTPRoute manifest template for dynamic sl-eap-HASH hostnames.",
            "Preflight gate approval for Phase 3 implementation."
        ],
        "testSurface": [
            "test -f docs/signalloom/slea-p3-pre-audit.md",
            "test -d d2-infra/components/ingress",
            "~/.claude/skills/ajm-auto-kanban/Tools/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLEA"
        ],
        "evidence": [
            "docs/signalloom/slea-p3-pre-audit.md with exact command and manifest citations.",
            "Verified template for Tailscale serve CLI parameters.",
            "Errata block appended for SLEA-P3-PRE with status=pass."
        ],
        "failureModes": [
            "Assuming Tailscale Funnel is permitted on all tailnets; must gracefully fall back to tailnet-only Serve mode.",
            "Designing routing that relies on hardcoded IP addresses rather than MagicDNS FQDNs."
        ],
        "stopAndReport": SHARED_STOP_AND_REPORT,
        "loopOn": [
            "test -f docs/signalloom/slea-p3-pre-audit.md"
        ],
        "outOfScope": SHARED_OUT_OF_SCOPE,
        "sharedFileRisks": [
            "Proposal Errata section — append-only qualified blocks."
        ],
        "consumesFromEarlierPhases": ["SLEA-P2-GOV certified REST API."],
        "mergeBoundary": "SLEA-P3-PRE commits to task worktree and merges via Phase 3 Governor.",
        "keyFacts": SHARED_KEY_FACTS
    },
    "P3-1": {
        "logicalId": "P3-1",
        "objective": (
            "Build the Tailscale EAP dynamic routing automation script in scripts/eap/tailscale-eap-env.sh. "
            "The script must provide subcommands: hash, provision, status, serve, and teardown. It must compute the "
            "salted hash for customer names (supporting 'kusari' -> 'a0314bec'), execute or mock 'tailscale serve' "
            "on target port 8080/443, manage Dex origin leases, and provide structured JSON output for automation."
        ),
        "approach": [
            "Create scripts/eap/tailscale-eap-env.sh with set -euo pipefail and structured argument parsing.",
            "Implement 'hash' command calling Python environment_routing.py or inline OpenSSL/SHA-256 derivation.",
            "Implement 'provision' command: generates hostname sl-eap-{hash}, writes environment state JSON.",
            "Implement 'serve' command: invokes tailscale serve https / http://127.0.0.1:8080 with mock fallback if TAILSCALE_MOCK=1.",
            "Implement 'teardown' command: invokes tailscale serve --reset and purges ephemeral state.",
            "Add comprehensive BATS / shell test suite verifying script commands and exit codes."
        ],
        "deliverables": [
            "scripts/eap/tailscale-eap-env.sh executable script with chmod +x.",
            "Subcommands: hash, provision, status, serve, teardown, help.",
            "Support for TAILSCALE_MOCK=1 for deterministic offline testing.",
            "Automated test script in scripts/eap/test_tailscale_eap_env.sh.",
            "Documented usage instructions and examples in script header."
        ],
        "testSurface": [
            "bash scripts/eap/tailscale-eap-env.sh hash --customer kusari",
            "bash scripts/eap/tailscale-eap-env.sh provision --customer kusari --mock",
            "bash scripts/eap/tailscale-eap-env.sh status --customer kusari --mock",
            "bash scripts/eap/tailscale-eap-env.sh teardown --customer kusari --mock",
            "bash scripts/eap/test_tailscale_eap_env.sh"
        ],
        "evidence": [
            "Captured CLI output verifying 'kusari' produces exact hash 'a0314bec' and hostname 'sl-eap-a0314bec'.",
            "Execution log from test_tailscale_eap_env.sh passing all subcommands.",
            "Errata block appended for SLEA-P3-1 with status=pass."
        ],
        "failureModes": [
            "Script hanging indefinitely on interactive prompts; must pass non-interactive flags (--yes, </dev/null).",
            "Failing to handle spaces or special characters in customer company names.",
            "Failure to cleanly exit with non-zero status when required arguments are missing."
        ],
        "stopAndReport": SHARED_STOP_AND_REPORT,
        "loopOn": [
            "bash scripts/eap/test_tailscale_eap_env.sh"
        ],
        "outOfScope": SHARED_OUT_OF_SCOPE,
        "sharedFileRisks": [
            "scripts/eap/tailscale-eap-env.sh — owned by P3-1.",
            "Proposal Errata section — append-only qualified blocks."
        ],
        "consumesFromEarlierPhases": ["SLEA-P3-PRE script specification."],
        "mergeBoundary": "SLEA-P3-1 commits to task worktree and merges via SLEA-P3-GOV.",
        "keyFacts": SHARED_KEY_FACTS
    },
    "P3-2": {
        "logicalId": "P3-2",
        "objective": (
            "Implement multi-tenant Envoy Ingress HTTPRoute manifest generation and Dex redirect origin reconciliation "
            "for dynamic sl-eap-HASH hostnames. Enable the platform to dynamically route traffic arriving on "
            "https://sl-eap-HASH.tailscale to the designated tenant service or frontend pod without restarting Envoy."
        ),
        "approach": [
            "Create Kubernetes HTTPRoute manifest template in d2-infra/components/ingress/eap-httproute-template.yaml.",
            "Configure hostname matchers for sl-eap-*.tailscale and sl-eap-*.ts.net.",
            "Implement Python/bash reconciler that renders and applies the HTTPRoute for active provisioned environments.",
            "Coordinate with Dex ConfigMap to add dynamic redirectURIs for active customer hostnames.",
            "Write manifest validation tests ensuring generated HTTPRoute resources pass kubectl validate."
        ],
        "deliverables": [
            "HTTPRoute template in d2-infra/components/ingress/eap-httproute-template.yaml.",
            "Dynamic HTTPRoute generator function in fe-signalloom/src/environment_routing.py.",
            "Dex origin update helper ensuring OAuth callbacks succeed for provisioned environments.",
            "Unit and contract tests verifying generated YAML manifests conform to Gateway API specs."
        ],
        "testSurface": [
            "pytest tests/test_environment_routing.py -k 'test_httproute_manifest_generation' -v",
            "test -f d2-infra/components/ingress/eap-httproute-template.yaml",
            "pytest tests/test_environment_routing.py -v"
        ],
        "evidence": [
            "Captured YAML manifest generated for 'kusari' matching hostname 'sl-eap-a0314bec'.",
            "Pytest execution log proving HTTPRoute generation logic passes.",
            "Errata block appended for SLEA-P3-2 with status=pass."
        ],
        "failureModes": [
            "Invalid Gateway API group or version in HTTPRoute manifest causing Kubernetes API rejection.",
            "Dex rejecting dynamic redirect URIs if wildcard matching is disabled in the OIDC client profile."
        ],
        "stopAndReport": SHARED_STOP_AND_REPORT,
        "loopOn": [
            "pytest tests/test_environment_routing.py -k 'test_httproute_manifest_generation' -v"
        ],
        "outOfScope": SHARED_OUT_OF_SCOPE,
        "sharedFileRisks": [
            "d2-infra/components/ingress/ — shared infrastructure; coordinate through governor.",
            "Proposal Errata section — append-only qualified blocks."
        ],
        "consumesFromEarlierPhases": ["SLEA-P3-1 script automation."],
        "mergeBoundary": "SLEA-P3-2 commits to task worktree and merges via SLEA-P3-GOV.",
        "keyFacts": SHARED_KEY_FACTS
    },
    "P3-GOV": {
        "logicalId": "P3-GOV",
        "objective": (
            "Certify Phase 3 deliverables: verify dynamic mesh routing, Dex callback stability, and Tailscale "
            "CLI automation. Execute synthetic end-to-end routing validation for 'sl-eap-a0314bec', confirm that "
            "Dex OIDC origin leases are maintained without race conditions, and audit script safety under error scenarios."
        ),
        "approach": [
            "Run full test suite in scripts/eap/test_tailscale_eap_env.sh.",
            "Run fe-signalloom pytest suite asserting HTTPRoute manifest rendering.",
            "Verify that kusari EAP environment endpoint generates valid Dex redirect URI https://sl-eap-a0314bec.tailscale/callback.",
            "Inspect script exit codes under simulated network failures to verify robust error handling.",
            "Run scripts/kanban-check.sh doctor and append certified errata block."
        ],
        "deliverables": [
            "Phase 3 certification report in docs/signalloom/slea-p3-gov-certification.md.",
            "Captured output from scripts/eap/test_tailscale_eap_env.sh.",
            "Captured pytest log verifying HTTPRoute and Dex origin lease mechanics.",
            "Certified errata block in proposal."
        ],
        "testSurface": [
            "bash scripts/eap/test_tailscale_eap_env.sh",
            "pytest tests/test_environment_routing.py -v",
            "~/.claude/skills/ajm-auto-kanban/Tools/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLEA"
        ],
        "evidence": [
            "docs/signalloom/slea-p3-gov-certification.md recording Phase 3 verification evidence.",
            "Captured clean execution of Tailscale routing automation suite.",
            "Errata block appended for SLEA-P3-GOV with status=pass."
        ],
        "failureModes": [
            "Incomplete teardown leaving orphaned route entries in Envoy Gateway table.",
            "Stale Dex origin leases preventing subsequent environment allocations."
        ],
        "stopAndReport": SHARED_STOP_AND_REPORT,
        "loopOn": [
            "bash scripts/eap/test_tailscale_eap_env.sh"
        ],
        "outOfScope": SHARED_OUT_OF_SCOPE,
        "sharedFileRisks": [
            "Proposal Errata section — append-only qualified blocks."
        ],
        "consumesFromEarlierPhases": ["SLEA-P3-1 and SLEA-P3-2 outputs."],
        "mergeBoundary": "SLEA-P3-GOV merges Phase 3 feature branch into integration line.",
        "keyFacts": SHARED_KEY_FACTS
    },
    "P4-PRE": {
        "logicalId": "P4-PRE",
        "objective": (
            "Audit tenant namespace templates, Flux ResourceSets, and teardown cleanup guards prior to Phase 4. "
            "Verify how ephemeral tenant namespaces (e.g. sl-eap-a0314bec) are isolated using Kubernetes NetworkPolicies, "
            "how OpenBao injects tenant-scoped credentials, and confirm teardown safety guards to ensure tenant "
            "deprovisioning never impacts foundation services."
        ),
        "approach": [
            "Inspect d2-osramp-fleet/ tenant definitions to understand ResourceSet tenancy patterns.",
            "Review NetworkPolicy templates to confirm default-deny ingress with scoped gateway allow-rules.",
            "Define teardown cleanup order: traffic cut -> pods terminate -> secrets shred -> namespace delete.",
            "Confirm that foundation namespaces (default, kube-system, ingress, flux-system) are immune to deletion.",
            "Document tenant isolation specifications in docs/signalloom/slea-p4-pre-audit.md."
        ],
        "deliverables": [
            "docs/signalloom/slea-p4-pre-audit.md documenting tenant isolation and safety guards.",
            "Safety guard check asserting system namespaces cannot be targeted by deprovisioning API.",
            "NetworkPolicy template providing multi-tenant isolation across EAP customer namespaces.",
            "Preflight gate approval for Phase 4 implementation."
        ],
        "testSurface": [
            "test -f docs/signalloom/slea-p4-pre-audit.md",
            "pytest tests/test_environment_routing.py -v",
            "~/.claude/skills/ajm-auto-kanban/Tools/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLEA"
        ],
        "evidence": [
            "docs/signalloom/slea-p4-pre-audit.md with exact security guard citations.",
            "Safety test proving system namespaces are protected from teardown.",
            "Errata block appended for SLEA-P4-PRE with status=pass."
        ],
        "failureModes": [
            "Accidental teardown targeting non-EAP namespaces like ingress or flux-system.",
            "Missing egress NetworkPolicies permitting cross-tenant pod communication."
        ],
        "stopAndReport": SHARED_STOP_AND_REPORT,
        "loopOn": [
            "test -f docs/signalloom/slea-p4-pre-audit.md"
        ],
        "outOfScope": SHARED_OUT_OF_SCOPE,
        "sharedFileRisks": [
            "Proposal Errata section — append-only qualified blocks."
        ],
        "consumesFromEarlierPhases": ["SLEA-P3-GOV certified mesh routing."],
        "mergeBoundary": "SLEA-P4-PRE commits to task worktree and merges via Phase 4 Governor.",
        "keyFacts": SHARED_KEY_FACTS
    },
    "P4-1": {
        "logicalId": "P4-1",
        "objective": (
            "Implement on-demand demo/UAT namespace bootstrapper and teardown garbage collector. "
            "Build the controller worker that reconciles environment requests into ephemeral Kubernetes namespaces "
            "(e.g. sl-eap-a0314bec), deploys tenant service bindings, monitors lease expiration, and automatically "
            "triggers cryptographic deprovisioning when TTL expires."
        ),
        "approach": [
            "Implement EnvironmentReconciler in environment_routing.py managing namespace lifecycle.",
            "Build namespace provisioner: creates namespace, applies tenant NetworkPolicy, labels with signalloom.io/eap-tenant.",
            "Build namespace deprovisioner: enforces strict prefix check (must start with sl-eap-), deletes ephemeral resources.",
            "Implement TTL background check: finds expired environments and marks status EXPIRED.",
            "Write comprehensive tests simulating complete provisioning -> TTL expiration -> cleanup loop."
        ],
        "deliverables": [
            "EnvironmentReconciler implementation in d2-signalloom/apps/fe-signalloom/src/environment_routing.py.",
            "Namespace bootstrapper with strict safety prefix validation (sl-eap-* only).",
            "Automated TTL expiration worker evaluating active environment lease times.",
            "Unit and mock integration tests in tests/test_environment_routing.py asserting lifecycle cleanup.",
            "Clean pytest run verifying namespace isolation and safety guards."
        ],
        "testSurface": [
            "pytest tests/test_environment_routing.py -k 'test_reconciler_provision_namespace' -v",
            "pytest tests/test_environment_routing.py -k 'test_reconciler_ttl_expiration' -v",
            "pytest tests/test_environment_routing.py -k 'test_safety_guard_rejects_system_ns' -v",
            "pytest tests/test_environment_routing.py -v"
        ],
        "evidence": [
            "Captured pytest log verifying namespace bootstrapper and TTL garbage collection.",
            "Log transcript proving safety guard rejects attempts to delete 'kube-system' or 'default'.",
            "Errata block appended for SLEA-P4-1 with status=pass."
        ],
        "failureModes": [
            "Namespace deletion hanging on finalizers or orphaned resources.",
            "Failing to enforce prefix guard allowing malicious teardown calls against foreign namespaces."
        ],
        "stopAndReport": SHARED_STOP_AND_REPORT,
        "loopOn": [
            "pytest tests/test_environment_routing.py -v"
        ],
        "outOfScope": SHARED_OUT_OF_SCOPE,
        "sharedFileRisks": [
            "d2-signalloom/apps/fe-signalloom/src/environment_routing.py — owned by P4-1 and P4-2.",
            "Proposal Errata section — append-only qualified blocks."
        ],
        "consumesFromEarlierPhases": ["SLEA-P4-PRE security audit."],
        "mergeBoundary": "SLEA-P4-1 commits to task worktree and merges via SLEA-P4-GOV.",
        "keyFacts": SHARED_KEY_FACTS
    },
    "P4-2": {
        "logicalId": "P4-2",
        "objective": (
            "Build comprehensive acceptance and purple-team test suite for the kusari EAP environment lifecycle. "
            "Assert the end-to-end journey: resolve domain -> provision environment -> verify HTTP 201 response -> "
            "verify hostname sl-eap-a0314bec -> probe Dex origin lease -> extend TTL -> initiate teardown -> verify clean state."
        ),
        "approach": [
            "Create dedicated acceptance test suite tests/test_kusari_eap_lifecycle.py.",
            "Simulate external API trigger for customer 'kusari' with 24-hour demo environment request.",
            "Assert response status 201, environment_id 'env-eap-a0314bec', hostname 'sl-eap-a0314bec', and URL 'https://sl-eap-a0314bec.tailscale'.",
            "Assert that calling resolve-domain returns identical hash and hostname.",
            "Assert that extending TTL by 12 hours updates expires_at correctly.",
            "Assert that teardown marks status TORN_DOWN and cleans up active lease records."
        ],
        "deliverables": [
            "Dedicated acceptance test file tests/test_kusari_eap_lifecycle.py.",
            "End-to-end verification of customer 'kusari' lifecycle from provision to teardown.",
            "Idempotence and edge-case validation tests.",
            "Full pytest pass across entire fe-signalloom test directory with zero warnings or failures."
        ],
        "testSurface": [
            "pytest tests/test_kusari_eap_lifecycle.py -v",
            "pytest tests/test_environment_routing.py -v",
            "pytest tests/ -v"
        ],
        "evidence": [
            "Captured pytest log showing 100% pass on kusari EAP acceptance suite.",
            "JSON transcript of full environment lifecycle states.",
            "Errata block appended for SLEA-P4-2 with status=pass."
        ],
        "failureModes": [
            "Flaky async test timing during TTL countdown assertions.",
            "Failing to clean up temporary test databases or state files after acceptance test runs."
        ],
        "stopAndReport": SHARED_STOP_AND_REPORT,
        "loopOn": [
            "pytest tests/test_kusari_eap_lifecycle.py -v"
        ],
        "outOfScope": SHARED_OUT_OF_SCOPE,
        "sharedFileRisks": [
            "Proposal Errata section — append-only qualified blocks."
        ],
        "consumesFromEarlierPhases": ["SLEA-P4-1 reconciler implementation."],
        "mergeBoundary": "SLEA-P4-2 commits to task worktree and merges via SLEA-P4-GOV.",
        "keyFacts": SHARED_KEY_FACTS
    },
    "P4-GOV": {
        "logicalId": "P4-GOV",
        "objective": (
            "Final mission certification for SLEA: verify complete end-to-end on-demand EAP environment routing, "
            "Tailscale provisioning engine, and customer kusari validation. Audit code coverage, documentation, "
            "API wire contracts, and ensure zero regressions across all repository test suites before declaring "
            "mission complete."
        ),
        "approach": [
            "Run all unit, integration, and acceptance tests in fe-signalloom.",
            "Run scripts/eap/test_tailscale_eap_env.sh CLI test suite.",
            "Verify that docs/Proposal — SLEA Signal Loom On-Demand EAP Environment Routing & Tailscale Provisioning Engine (2026-Q3).md has clean errata.",
            "Run scripts/kanban-check.sh doctor --shortcode SLEA to confirm zero unresolved defects.",
            "Publish mission certification record in docs/signalloom/slea-mission-complete.md and append final errata block."
        ],
        "deliverables": [
            "Final mission certification document in docs/signalloom/slea-mission-complete.md.",
            "Complete green test run across Python, shell, and acceptance suites.",
            "Clean kanban-check doctor verification with zero warnings.",
            "Final errata block in proposal marking Phase 4 certified."
        ],
        "testSurface": [
            "pytest tests/test_kusari_eap_lifecycle.py -v",
            "pytest tests/test_environment_routing.py -v",
            "bash scripts/eap/test_tailscale_eap_env.sh",
            "~/.claude/skills/ajm-auto-kanban/Tools/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLEA"
        ],
        "evidence": [
            "docs/signalloom/slea-mission-complete.md detailing full mission certification.",
            "Captured test logs demonstrating 100% green status across all suites.",
            "Errata block appended for SLEA-P4-GOV with status=pass."
        ],
        "failureModes": [
            "Declaring victory while any acceptance check is mocked rather than executed.",
            "Leaving uncommitted temporary files in git status."
        ],
        "stopAndReport": SHARED_STOP_AND_REPORT,
        "loopOn": [
            "pytest tests/test_kusari_eap_lifecycle.py -v"
        ],
        "outOfScope": SHARED_OUT_OF_SCOPE,
        "sharedFileRisks": [
            "Proposal Errata section — append-only qualified blocks."
        ],
        "consumesFromEarlierPhases": ["All prior SLEA phases."],
        "mergeBoundary": "SLEA-P4-GOV certifies mission and seals the SLEA release.",
        "keyFacts": SHARED_KEY_FACTS
    }
}

def main():
    proposal_path = Path("/home/andy/Documents/Obsidian/v1/2. Areas/CEO/Innovation Proposals/Proposal — SLEA Signal Loom On-Demand EAP Environment Routing & Tailscale Provisioning Engine (2026-Q3).md")
    import hashlib
    contract_sha = hashlib.sha256(proposal_path.read_bytes()).hexdigest()
    
    count = 0
    for logical_id, card_spec in SPECS.items():
        card_spec = cc.apply_card_contract(card_spec, repo_root=cc.REPO_ROOT)
        spec_payload = {
            "specCacheVersion": 1,
            "shortcode": "SLEA",
            "logicalId": logical_id,
            "proposalContractSha256": contract_sha,
            "cachedAt": "2026-09-17T20:00:00Z",
            "cardSpecification": card_spec
        }
        out_file = SPEC_DIR / f"{logical_id}.v1.json"
        out_file.write_text(json.dumps(spec_payload, indent=2))
        count += 1
        print(f"Wrote {out_file} (objectives: {len(card_spec['objective'].split())} words)")

    print(f"\nSuccessfully generated {count} council-grade card specifications for SLEA.")

if __name__ == "__main__":
    main()
