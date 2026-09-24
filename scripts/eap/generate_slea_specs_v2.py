#!/usr/bin/env python3
"""Generates fully compliant council-grade card specifications for SLEA.

Ensures all 17 cards strictly meet and exceed prompt-contract.py SPEC_FLOORS:
  - S: words >= 250, lines >= 20, deliverables >= 4, tests >= 3 (exempt for gov/preflight)
  - M: words >= 450, lines >= 35, deliverables >= 5, tests >= 4 (exempt for gov/preflight)
  - L: words >= 700, lines >= 50, deliverables >= 6, tests >= 5 (exempt for gov/preflight)
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path

# Load prompt-contract spec_metrics
pc_spec = importlib.util.spec_from_file_location(
    "prompt_contract",
    "/home/andy/.claude/skills/ajm-auto-kanban/Tools/prompt-contract.py"
)
pc = importlib.util.module_from_spec(pc_spec)
pc_spec.loader.exec_module(pc)

SPEC_DIR = Path.home() / ".cline" / "kanban" / "card-specs" / "SLEA"
SPEC_DIR.mkdir(parents=True, exist_ok=True)

PROPOSAL_PATH = Path(
    "/home/andy/Documents/Obsidian/v1/2. Areas/CEO/Innovation Proposals/"
    "Proposal — SLEA Signal Loom On-Demand EAP Environment Routing & Tailscale Provisioning Engine (2026-Q3).md"
)
CONTRACT_SHA = hashlib.sha256(PROPOSAL_PATH.read_bytes()).hexdigest()

COMMON_OUT_OF_SCOPE = [
    "Modifying existing SLER kernel telemetry modules or eBPF probe definitions.",
    "Modifying SLDP OpenBao Transit key derivation or customer encryption primitives.",
    "Ingesting or logging customer proprietary source code, prompts, or completion tokens.",
    "Hardcoding cloud credentials, API tokens, or static secrets in git-tracked files.",
    "Modifying production Gateway API Envoy listeners without approval.",
    "Bypassing cryptographic salt derivation using un-salted plain company names.",
    "Creating permanent cloud DNS records outside of Tailscale MagicDNS automation."
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

# Definitions for all cards
RAW_SPECS = {}

# P0: S implementation
RAW_SPECS["P0"] = make_spec(
    "P0", "S", "implementation",
    obj=(
        "Establish and verify the initial environment routing baseline, Tailscale CLI fixtures, "
        "and Python test harness for the SLEA mission. Verify that the repository is clean, "
        "that d2-signalloom/apps/fe-signalloom/src test suite executes cleanly under pytest, and "
        "that the kanban-check doctor passes with zero anomalies before any environment routing "
        "or dynamic provisioning code is introduced."
    ),
    approach=[
        "Run scripts/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLEA to capture baseline state.",
        "Inspect d2-signalloom/apps/fe-signalloom/src/main.py to inventory all installed API routers and lifecycle hooks.",
        "Run pytest on fe-signalloom/src/tests to confirm baseline passing state across existing suites.",
        "Verify Tailscale mock harness and environment variables (SIGNAL_LOOM_EAP_SALT, TAILSCALE_AUTH_KEY).",
        "Document baseline findings, installed packages, and test coverage in docs/signalloom/slea-p0-baseline.md.",
        "Construct initial test scaffold in fe-signalloom/src/tests/test_environment_routing.py asserting harness readiness.",
        "Confirm that git worktree isolation and integration branch ref refs/heads/integration/slea-v0.1.0 exist."
    ],
    deliverables=[
        "docs/signalloom/slea-p0-baseline.md recording harness identity, existing router inventory, and test baseline.",
        "Clean test run output from fe-signalloom test suite attached as baseline evidence in docs/signalloom/.",
        "Baseline doctor check output proving zero uncompiled cards or broken dependencies in kanban.",
        "Initial test harness fixture in tests/test_environment_routing.py asserting test harness readiness."
    ],
    tests=[
        "pytest tests/test_environment_routing.py -v",
        "~/.claude/skills/ajm-auto-kanban/Tools/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLEA",
        "test -f docs/signalloom/slea-p0-baseline.md",
        "pytest tests/test_coding_agent_telemetry.py"
    ],
    evidence=[
        "docs/signalloom/slea-p0-baseline.md with citations of all inspected router files.",
        "Captured pytest execution log demonstrating 100% pass on baseline fixtures.",
        "Captured kanban-check doctor output with clean status.",
        "Errata block appended for SLEA-P0 with status=pass."
    ],
    failures=[
        "Assuming Tailscale binary is installed in default PATH without fallback or mock mode for local unit tests.",
        "Assuming fe-signalloom uses a global virtualenv rather than local python3 / pytest runtime.",
        "Failing to capture existing router list leading to duplicate prefix collisions.",
        "Uncommitted temporary test files dirtying the git status."
    ]
)

# P1-PRE: S preflight
RAW_SPECS["P1-PRE"] = make_spec(
    "P1-PRE", "S", "preflight",
    obj=(
        "Audit customer hashing salt, DNS label constraints, and Tailscale MagicDNS contracts. "
        "Verify RFC 1123 compliance for generated sl-eap-HASH subdomains, confirm the canonical test vector "
        "for initial customer 'kurasi', and verify that the proposed cryptographic salt structure prevents "
        "both rainbow table inversion and domain collisions."
    ),
    approach=[
        "Verify salt derivation contract using default salt 'signalloom-eap-salt-2026-q3' or SIGNAL_LOOM_EAP_SALT.",
        "Calculate SHA-256('signalloom-eap-salt-2026-q3:kurasi') and confirm truncated 8-character hex prefix '6f82ad81'.",
        "Validate hostname 'sl-eap-6f82ad81' against RFC 1123 label constraints (lowercase alphanumeric and hyphens, <= 63 chars).",
        "Inspect Tailscale Serve and Funnel domain structures ensuring compatibility with *.tailscale and *.ts.net.",
        "Document salt audit findings and canonical hash vector in docs/signalloom/slea-p1-preflight.md."
    ],
    deliverables=[
        "docs/signalloom/slea-p1-preflight.md with cryptographic hash audit and RFC 1123 regex specifications.",
        "Python script or verification snippet confirming 'kurasi' yields '6f82ad81' under canonical salt.",
        "Regex validation specification for sl-eap-HASH hostname formats.",
        "Errata block for SLEA-P1-PRE appended to proposal."
    ],
    tests=[
        "python3 -c \"import hashlib; assert hashlib.sha256(b'signalloom-eap-salt-2026-q3:kurasi').hexdigest()[:8] == '6f82ad81'\"",
        "test -f docs/signalloom/slea-p1-preflight.md",
        "git status --porcelain"
    ],
    evidence=[
        "docs/signalloom/slea-p1-preflight.md recording verification steps and hash outputs.",
        "Captured test output showing successful assertion of canonical kurasi vector.",
        "Errata block appended for SLEA-P1-PRE with status=pass."
    ],
    failures=[
        "Using case-sensitive customer names leading to hash mismatch ('Kurasi' vs 'kurasi'); must lowercase and strip.",
        "Omitting salt delimiter leading to collision vulnerabilities (e.g. 'salt' + 'name' vs 'salt:name').",
        "Generating hostname longer than 63 characters violating DNS RFC 1123."
    ]
)

# P1-1: M implementation (>=450w, >=35l, >=5d, >=4t)
RAW_SPECS["P1-1"] = make_spec(
    "P1-1", "M", "implementation",
    obj=(
        "Build the cryptographic salt hashing engine, URL generator, and subdomain validator in "
        "d2-signalloom/apps/fe-signalloom/src/environment_routing.py. Implement derive_customer_hash "
        "which normalizes customer names, applies the configured or default salt, and extracts the 8-character "
        "hexadecimal hash. Build build_environment_urls returning both internal tailnet mesh URL "
        "(https://sl-eap-{hash}.tailscale) and external MagicDNS FQDN (https://sl-eap-{hash}.ts.net). "
        "Implement validate_environment_subdomain ensuring strict adherence to RFC 1123 DNS standards. "
        "Write comprehensive unit tests in fe-signalloom/src/tests/test_environment_routing.py covering "
        "the canonical 'kurasi' vector, case normalization, whitespace stripping, and collision resistance."
    ),
    approach=[
        "Create d2-signalloom/apps/fe-signalloom/src/environment_routing.py if not already present.",
        "Implement DEFAULT_EAP_SALT = 'signalloom-eap-salt-2026-q3' with os.getenv('SIGNAL_LOOM_EAP_SALT') override.",
        "Define derive_customer_hash(company_name: str, salt: str | None = None) -> str with lowercasing and strip.",
        "Enforce format f'{salt}:{normalized_company}' before computing SHA-256 digest and truncating to 8 hex chars.",
        "Implement build_environment_urls(hash_val: str) -> dict[str, str] returning internal_mesh and external_fqdn.",
        "Implement validate_environment_subdomain(subdomain: str) -> bool matching ^sl-eap-[a-f0-9]{8}$.",
        "Implement resolve_company_to_urls(company_name: str, salt: str | None = None) -> dict[str, str] helper.",
        "Add unit tests in tests/test_environment_routing.py verifying that 'kurasi' strictly resolves to '6f82ad81'.",
        "Add unit tests testing edge cases: company names with uppercase letters, leading/trailing whitespace, and symbols.",
        "Add collision resistance tests hashing 1,000 synthetic company names ensuring zero 8-char collisions in test suite.",
        "Document hashing algorithm and cryptographic rationale in docs/signalloom/slea-p1-hashing-engine.md."
    ],
    deliverables=[
        "d2-signalloom/apps/fe-signalloom/src/environment_routing.py with derive_customer_hash and URL generators.",
        "fe-signalloom/src/tests/test_environment_routing.py with unit tests for canonical kurasi vector and normalization.",
        "Collision resistance test suite verifying uniqueness across sample enterprise customer rosters.",
        "RFC 1123 hostname validation function and corresponding negative test cases.",
        "docs/signalloom/slea-p1-hashing-engine.md documenting the cryptographic hashing and URL generation specifications.",
        "Append-only errata entry for SLEA-P1-1 in proposal markdown."
    ],
    tests=[
        "pytest tests/test_environment_routing.py -k test_derive_customer_hash_kurasi -v",
        "pytest tests/test_environment_routing.py -k test_build_environment_urls -v",
        "pytest tests/test_environment_routing.py -k test_validate_environment_subdomain -v",
        "pytest tests/test_environment_routing.py -k test_hash_collision_resistance -v",
        "pytest tests/test_environment_routing.py -v"
    ],
    evidence=[
        "Captured pytest execution log demonstrating 100% pass on hashing and URL generator tests.",
        "Assertion output showing kurasi yields exactly 6f82ad81 and https://sl-eap-6f82ad81.tailscale.",
        "docs/signalloom/slea-p1-hashing-engine.md with complete function signatures and docstrings.",
        "Errata block appended for SLEA-P1-1 with status=pass."
    ],
    failures=[
        "Modifying company name casing without normalization, causing different URLs for Kurasi vs kurasi.",
        "Truncating hash to fewer than 8 characters increasing collision probability in multi-tenant fleets.",
        "Using non-hex characters or uppercase letters in URL hostnames violating RFC 1123.",
        "Hardcoding the salt string directly in call sites rather than using centralized constant and env var fallback.",
        "Allowing empty or whitespace-only company names to be hashed without validation error."
    ]
)

# P1-2: M implementation (>=450w, >=35l, >=5d, >=4t)
RAW_SPECS["P1-2"] = make_spec(
    "P1-2", "M", "implementation",
    obj=(
        "Define environment provisioning data models, schema validations, and lifecycle state machines in "
        "d2-signalloom/apps/fe-signalloom/src/environment_routing.py. Create Pydantic v2 schemas for "
        "ProvisionRequest, EnvironmentResponse, DomainResolutionRequest, DomainResolutionResponse, "
        "ExtendTtlRequest, and TeardownRequest. Implement EnvironmentState enum with states PENDING, "
        "PROVISIONING, READY, DEGRADED, EXPIRING, TEARING_DOWN, and TERMINATED. Enforce strict input validation "
        "on customer company name, environment tier, initial TTL minutes (default 240, max 1440), and "
        "feature flags. Implement in-memory/SQLite thread-safe registry for active EAP environments."
    ),
    approach=[
        "Define EnvironmentState enum with valid lifecycle states and transition validation rules.",
        "Define ProvisionRequest model with fields: company_name, tier (demo, uat, pilot), ttl_minutes, metadata.",
        "Enforce Field(..., min_length=2, max_length=64) on company_name with regex validation preventing injection.",
        "Define EnvironmentResponse model containing id, company_name, customer_hash, internal_mesh_url, external_fqdn, state, created_at, expires_at.",
        "Define DomainResolutionRequest and DomainResolutionResponse models for quick DNS mapping lookups.",
        "Define ExtendTtlRequest model accepting additional_minutes (1..1440) with ceiling guard (max 72 hours total).",
        "Define TeardownRequest model accepting reason and force flags.",
        "Implement EnvironmentRegistry class providing thread-safe CRUD operations and state transition methods.",
        "Write unit tests validating Pydantic schemas, field boundary limits, and state transition invariants.",
        "Document schema definitions and lifecycle state transitions in docs/signalloom/slea-p1-data-models.md."
    ],
    deliverables=[
        "Pydantic data models for environment provisioning in fe-signalloom/src/environment_routing.py.",
        "EnvironmentState enum and state transition validator enforcing monotonic lifecycle progression.",
        "Thread-safe EnvironmentRegistry class managing active environment records and TTL tracking.",
        "Comprehensive unit test suite in fe-signalloom/src/tests/test_environment_models.py.",
        "docs/signalloom/slea-p1-data-models.md documenting JSON schemas, state diagrams, and field constraints.",
        "Append-only errata entry for SLEA-P1-2 in proposal markdown."
    ],
    tests=[
        "pytest tests/test_environment_models.py -k test_provision_request_validation -v",
        "pytest tests/test_environment_models.py -k test_environment_state_transitions -v",
        "pytest tests/test_environment_models.py -k test_environment_registry_crud -v",
        "pytest tests/test_environment_models.py -k test_ttl_ceiling_enforcement -v",
        "pytest tests/test_environment_routing.py -v"
    ],
    evidence=[
        "Captured pytest log demonstrating 100% pass on model and registry test cases.",
        "JSON schema dump verifying valid OpenAPI generation from Pydantic models.",
        "docs/signalloom/slea-p1-data-models.md with complete Mermaid state diagram.",
        "Errata block appended for SLEA-P1-2 with status=pass."
    ],
    failures=[
        "Permitting invalid state transitions (e.g. from TERMINATED back to READY).",
        "Allowing negative or excessively large TTL values causing integer overflow or indefinite resource leases.",
        "Missing thread-safety guards on environment registry causing race conditions during concurrent provisioning.",
        "Failing to serialize datetime objects into ISO 8601 strings in JSON response payloads.",
        "Accepting company names with shell metacharacters that could be passed to CLI scripts."
    ]
)

# P1-GOV: M governor (>=450w, >=35l, >=5d, tests exempt)
RAW_SPECS["P1-GOV"] = make_spec(
    "P1-GOV", "M", "governor",
    obj=(
        "Phase 1 Governor Certification: independently verify customer hashing contracts, canonical kurasi "
        "vector, domain generation rules, and data model validations. Audit the integration of environment_routing.py, "
        "confirm that 100 random company test vectors produce zero domain collisions, verify RFC 1123 compliance, "
        "and certify that Phase 1 deliverables meet all architectural standards. Reconcile all Phase 1 commits, "
        "update proposal errata, and certify readiness to proceed to Phase 2 REST API development."
    ),
    approach=[
        "Checkout dedicated Governor worktree or review integration branch integration/slea-v0.1.0.",
        "Execute automated kurasi verification check asserting exact match with 6f82ad81 and https://sl-eap-6f82ad81.tailscale.",
        "Run collision simulation against 1,000 enterprise company names with salt signalloom-eap-salt-2026-q3.",
        "Review Pydantic schemas in environment_routing.py for input sanitization and security boundaries.",
        "Confirm that zero uncommitted files or linting violations exist across the codebase.",
        "Run kanban-check doctor to assert graph integrity and verify zero orphaned or degraded cards.",
        "Author Phase 1 certification document in docs/signalloom/slea-p1-certification.md.",
        "Append qualified Phase 1 completion errata block to proposal markdown."
    ],
    deliverables=[
        "docs/signalloom/slea-p1-certification.md certifying Phase 1 hashing and data model completion.",
        "Automated governor verification script validating kurasi canonical vector and RFC 1123 compliance.",
        "Clean doctor check report from kanban-check confirming zero board defects.",
        "Updated integration branch merging SLEA-P1-1 and SLEA-P1-2 commits.",
        "Phase 1 Governor errata block appended to proposal markdown with status=pass."
    ],
    tests=[
        "python3 -c \"from environment_routing import derive_customer_hash, build_environment_urls; assert derive_customer_hash('kurasi') == '6f82ad81'\"",
        "pytest tests/test_environment_routing.py tests/test_environment_models.py -v",
        "~/.claude/skills/ajm-auto-kanban/Tools/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLEA"
    ],
    evidence=[
        "docs/signalloom/slea-p1-certification.md signed with verification artifacts.",
        "Green test run outputs from Python test suites and hash verification checks.",
        "Clean kanban-check doctor output with zero errors.",
        "Errata block appended for SLEA-P1-GOV with status=pass."
    ],
    failures=[
        "Certifying Phase 1 while canonical vector kurasi yields any value other than 6f82ad81.",
        "Overlooking case sensitivity bugs where Kurasi and kurasi generate divergent hashes.",
        "Allowing dirty working tree or unmerged branch artifacts into the integration baseline.",
        "Failing to document cryptographic parameters in the certification report."
    ]
)

# P2-PRE: S preflight (>=250w, >=20l, >=4d, tests exempt)
RAW_SPECS["P2-PRE"] = make_spec(
    "P2-PRE", "S", "preflight",
    obj=(
        "Audit FastAPI router seams, route prefix conventions, and Dex OIDC origin leasing hooks in "
        "d2-signalloom/apps/fe-signalloom/src/main.py. Confirm how environment routing endpoints will mount "
        "under /api/v1/environments, verify error handling middleware, and check Dex OIDC redirect URI whitelist "
        "mechanisms to prevent login bounce failures when redirecting from dynamic sl-eap-HASH domains."
    ),
    approach=[
        "Inspect fe-signalloom/src/main.py and all currently mounted routers to ensure /api/v1/environments is unique.",
        "Analyze Dex OIDC configuration and dynamic redirect origin leasing mechanisms (dex_origin apply tailscale).",
        "Examine FastAPI dependency injection patterns (auth, database, telemetry) used by existing routers.",
        "Verify CORS middleware configuration to permit dynamic https://sl-eap-*.tailscale origins.",
        "Draft preflight audit document in docs/signalloom/slea-p2-preflight.md with router registration blueprint."
    ],
    deliverables=[
        "docs/signalloom/slea-p2-preflight.md detailing router mount seams, CORS policies, and Dex OIDC origins.",
        "FastAPI router registration blueprint function install_environment_routing_api(app).",
        "CORS regex policy allowing *.tailscale and *.ts.net subdomains.",
        "Errata block appended for SLEA-P2-PRE in proposal markdown."
    ],
    tests=[
        "pytest tests/test_main.py -v",
        "test -f docs/signalloom/slea-p2-preflight.md",
        "git status --porcelain"
    ],
    evidence=[
        "docs/signalloom/slea-p2-preflight.md with complete router seam analysis.",
        "Captured test output showing clean baseline router execution.",
        "Errata block appended for SLEA-P2-PRE with status=pass."
    ],
    failures=[
        "Mounting router at conflicting path overlapping with existing fleet or agent endpoints.",
        "Omitting CORS headers causing browser clients to block cross-origin API requests from tailscale mesh.",
        "Failing to account for Dex redirect validation resulting in OAuth loop errors."
    ]
)

# P2-1: L implementation (>=700w, >=50l, >=6d, >=5t)
RAW_SPECS["P2-1"] = make_spec(
    "P2-1", "L", "implementation",
    obj=(
        "Implement the core environment provisioning and domain resolution REST endpoints in "
        "d2-signalloom/apps/fe-signalloom/src/environment_routing.py. Build POST /api/v1/environments/provision "
        "which accepts a ProvisionRequest, validates input, derives customer hash (e.g. 6f82ad81 for kurasi), "
        "computes internal mesh and external FQDN URLs, initializes environment state to PROVISIONING, registers the "
        "environment in the thread-safe registry, and returns HTTP 201 Created with EnvironmentResponse. "
        "Build POST /api/v1/environments/resolve-domain which accepts a DomainResolutionRequest (by company_name "
        "or customer_hash) and returns HTTP 200 OK with DomainResolutionResponse containing mapped hostnames. "
        "Enforce comprehensive HTTP error boundaries: 400 Bad Request for malformed names, 409 Conflict for duplicate "
        "active environments, and 422 Unprocessable Entity for invalid TTL values. Wire the router into main.py via "
        "install_environment_routing_api(app) and write rigorous FastAPI TestClient tests."
    ),
    approach=[
        "Create APIRouter(prefix='/api/v1/environments', tags=['environments']) in environment_routing.py.",
        "Implement POST /provision endpoint accepting ProvisionRequest with status_code=status.HTTP_201_CREATED.",
        "In /provision, derive customer hash using derive_customer_hash and construct URLs via build_environment_urls.",
        "Check registry for existing active environment with the same hash; if active, raise HTTPException(409, 'Environment already active').",
        "Create EnvironmentRecord in registry with status READY or PROVISIONING, created_at, and expires_at.",
        "Implement POST /resolve-domain endpoint accepting DomainResolutionRequest with company_name or customer_hash.",
        "In /resolve-domain, look up existing environment or calculate deterministic deterministic mapping on-demand.",
        "Implement error handlers for validation errors, duplicate keys, and invalid input strings.",
        "Implement install_environment_routing_api(app: FastAPI) -> None function to mount the router.",
        "Update fe-signalloom/src/main.py to call install_environment_routing_api during application initialization.",
        "Write comprehensive FastAPI TestClient test suite in fe-signalloom/src/tests/test_environment_api.py.",
        "Test POST /provision with canonical 'kurasi' vector asserting 201 Created, hash '6f82ad81', and URL 'https://sl-eap-6f82ad81.tailscale'.",
        "Test duplicate provisioning attempts asserting 409 Conflict.",
        "Test malformed company names and negative TTL values asserting appropriate 400/422 status codes.",
        "Document API contract, request/response examples, and OpenAPI schemas in docs/signalloom/slea-p2-api-endpoints.md."
    ],
    deliverables=[
        "FastAPI router in fe-signalloom/src/environment_routing.py implementing /provision and /resolve-domain.",
        "Router installation helper install_environment_routing_api wired into fe-signalloom/src/main.py.",
        "Comprehensive API test suite in fe-signalloom/src/tests/test_environment_api.py with 100% endpoint coverage.",
        "Kurasi verification API test asserting exact 201 Created response with hash 6f82ad81 and mesh URL.",
        "Error handling test cases covering 400, 409, and 422 HTTP status codes.",
        "docs/signalloom/slea-p2-api-endpoints.md detailing OpenAPI schemas and curl request examples.",
        "Append-only errata entry for SLEA-P2-1 in proposal markdown."
    ],
    tests=[
        "pytest tests/test_environment_api.py -k test_provision_kurasi_success -v",
        "pytest tests/test_environment_api.py -k test_provision_duplicate_conflict -v",
        "pytest tests/test_environment_api.py -k test_resolve_domain_by_name -v",
        "pytest tests/test_environment_api.py -k test_resolve_domain_by_hash -v",
        "pytest tests/test_environment_api.py -k test_provision_validation_errors -v",
        "pytest tests/test_environment_api.py -v"
    ],
    evidence=[
        "Captured pytest execution log demonstrating 100% pass on /provision and /resolve-domain endpoints.",
        "HTTP response transcript proving kurasi provisions to sl-eap-6f82ad81 with HTTP 201.",
        "docs/signalloom/slea-p2-api-endpoints.md with complete OpenAPI specification extracts.",
        "Errata block appended for SLEA-P2-1 with status=pass."
    ],
    failures=[
        "Returning 200 OK instead of 201 Created on successful resource creation.",
        "Failing to detect duplicate active environments resulting in conflicting database records.",
        "Leaking internal exception tracebacks in HTTP 500 error responses.",
        "Failing to normalize customer company names before conflict checking in the registry.",
        "Omitting required CORS headers on new API router endpoints."
    ]
)

# P2-2: L implementation (>=700w, >=50l, >=6d, >=5t)
RAW_SPECS["P2-2"] = make_spec(
    "P2-2", "L", "implementation",
    obj=(
        "Implement the complete environment lifecycle management endpoints in "
        "d2-signalloom/apps/fe-signalloom/src/environment_routing.py. Build GET /api/v1/environments "
        "to list active and historical environments with status filtering and pagination. Build "
        "GET /api/v1/environments/{id} to retrieve real-time status, health metrics, and TTL remaining for "
        "a specific environment. Build POST /api/v1/environments/{id}/extend to extend an environment's TTL "
        "by a specified number of minutes, enforcing a maximum lifetime ceiling of 72 hours. Build "
        "POST /api/v1/environments/{id}/teardown to initiate orderly de-provisioning, transitioning state "
        "through TEARING_DOWN to TERMINATED. Write extensive integration tests verifying state transitions, "
        "TTL expiration countdowns, and idempotent teardown handling."
    ),
    approach=[
        "Implement GET /api/v1/environments endpoint supporting query parameters status, limit, and offset.",
        "Implement GET /api/v1/environments/{id} endpoint returning detailed EnvironmentDetailResponse or 404 Not Found.",
        "Implement POST /api/v1/environments/{id}/extend endpoint accepting ExtendTtlRequest.",
        "In /extend, validate additional_minutes, calculate new expires_at, and enforce 72-hour hard cap from created_at.",
        "Implement POST /api/v1/environments/{id}/teardown endpoint accepting optional TeardownRequest with reason.",
        "In /teardown, transition state to TEARING_DOWN, trigger cleanup handlers, and mark TERMINATED.",
        "Ensure teardown is idempotent: calling teardown on an already TERMINATED environment returns 200 OK.",
        "Implement background TTL audit check helper check_expired_environments(registry) -> list[str].",
        "Add unit and integration tests in tests/test_environment_lifecycle.py testing list, get, extend, and teardown.",
        "Test TTL extension boundary conditions (valid extension, exceeding max cap, extending terminated environment).",
        "Test idempotency of teardown endpoint across multiple sequential calls.",
        "Document lifecycle endpoints, query parameters, and error responses in docs/signalloom/slea-p2-lifecycle-api.md."
    ],
    deliverables=[
        "GET /api/v1/environments endpoint with filtering and pagination in environment_routing.py.",
        "GET /api/v1/environments/{id} endpoint with detailed status and TTL metrics.",
        "POST /api/v1/environments/{id}/extend endpoint with lifetime ceiling enforcement.",
        "POST /api/v1/environments/{id}/teardown endpoint with idempotent teardown logic.",
        "Comprehensive lifecycle test suite in fe-signalloom/src/tests/test_environment_lifecycle.py.",
        "docs/signalloom/slea-p2-lifecycle-api.md documenting lifecycle endpoints and state transitions.",
        "Append-only errata entry for SLEA-P2-2 in proposal markdown."
    ],
    tests=[
        "pytest tests/test_environment_lifecycle.py -k test_list_environments_filtering -v",
        "pytest tests/test_environment_lifecycle.py -k test_get_environment_by_id -v",
        "pytest tests/test_environment_lifecycle.py -k test_extend_ttl_success -v",
        "pytest tests/test_environment_lifecycle.py -k test_extend_ttl_exceeds_max_cap -v",
        "pytest tests/test_environment_lifecycle.py -k test_teardown_idempotency -v",
        "pytest tests/test_environment_lifecycle.py -v"
    ],
    evidence=[
        "Captured pytest execution log demonstrating 100% pass across all lifecycle endpoints.",
        "Execution trace showing successful extension of kurasi environment TTL followed by clean teardown.",
        "docs/signalloom/slea-p2-lifecycle-api.md with complete API documentation.",
        "Errata block appended for SLEA-P2-2 with status=pass."
    ],
    failures=[
        "Allowing TTL extensions beyond the 72-hour absolute maximum ceiling.",
        "Returning 500 error when tearing down an already terminated environment rather than 200 OK.",
        "Failing to update expires_at timestamp accurately in the registry upon extension.",
        "Allowing TTL extension on terminated or expired environments.",
        "Pagination errors resulting in infinite loops or skipped environment records."
    ]
)

# P2-GOV: M governor (>=450w, >=35l, >=5d, tests exempt)
RAW_SPECS["P2-GOV"] = make_spec(
    "P2-GOV", "M", "governor",
    obj=(
        "Phase 2 Governor Certification: independently verify all REST API endpoints for on-demand environment "
        "provisioning, domain resolution, and lifecycle management. Audit OpenAPI schema generation, verify HTTP status "
        "code contracts (200, 201, 400, 404, 409, 422), test concurrent provisioning requests for thread safety, and "
        "confirm that the kurasi canonical vector provisions and resolves flawlessly. Reconcile all Phase 2 code into the "
        "integration branch, run the full test suite, author certification documentation, and certify readiness for "
        "Phase 3 Tailscale and Envoy Ingress automation."
    ),
    approach=[
        "Review git diff of all Phase 2 commits in environment_routing.py and main.py.",
        "Execute full test suite across fe-signalloom ensuring 100% pass with zero regressions.",
        "Run concurrent provisioning stress test issuing 50 simulated parallel requests to verify registry thread safety.",
        "Audit OpenAPI schema generated at /openapi.json ensuring accurate type definitions and status codes.",
        "Verify that kurasi canonical vector correctly yields https://sl-eap-6f82ad81.tailscale via API call.",
        "Check kanban board health with kanban-check doctor ensuring zero anomalies.",
        "Author Phase 2 certification document in docs/signalloom/slea-p2-certification.md.",
        "Append qualified Phase 2 completion errata block to proposal markdown."
    ],
    deliverables=[
        "docs/signalloom/slea-p2-certification.md detailing Phase 2 REST API validation and concurrency audit.",
        "Automated governor verification script executing end-to-end API test against TestClient.",
        "Captured test output showing 100% pass across all environment routing API suites.",
        "Clean kanban-check doctor status report.",
        "Phase 2 Governor errata block appended to proposal markdown with status=pass."
    ],
    tests=[
        "pytest tests/test_environment_api.py tests/test_environment_lifecycle.py -v",
        "pytest tests/ -v",
        "~/.claude/skills/ajm-auto-kanban/Tools/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLEA"
    ],
    evidence=[
        "docs/signalloom/slea-p2-certification.md signed with verification artifacts.",
        "Green test run outputs demonstrating zero failures across all test suites.",
        "Clean doctor output verifying healthy board state.",
        "Errata block appended for SLEA-P2-GOV with status=pass."
    ],
    failures=[
        "Certifying Phase 2 while any endpoint test fails or exhibits race conditions under concurrency.",
        "Overlooking schema validation bypasses that allow invalid characters into hostnames.",
        "Merging unformatted or unlinted code into the integration branch.",
        "Failing to capture complete OpenAPI contract in documentation."
    ]
)

# P3-PRE: S preflight (>=250w, >=20l, >=4d, tests exempt)
RAW_SPECS["P3-PRE"] = make_spec(
    "P3-PRE", "S", "preflight",
    obj=(
        "Audit Tailscale CLI automation capabilities, Tailscale Serve/Funnel contracts, and Envoy Gateway API "
        "HTTPRoute seams. Verify that tailscale serve commands support port-forwarding to local frontend/backend pods, "
        "confirm --accept-dns=false semantics to avoid disrupting host resolv.conf, audit Envoy Gateway HTTPRoute CRD "
        "versions installed in the cluster, and verify Dex OIDC dynamic redirect origin integration before building "
        "the shell automation engine."
    ),
    approach=[
        "Probe Tailscale CLI binary availability or verify mock harness fallback TAILSCALE_MOCK=1.",
        "Inspect Envoy Gateway HTTPRoute CRDs (gateway.networking.k8s.io/v1) in d2-infra/components/ingress/.",
        "Audit Dex OIDC configmap to identify dynamic origin registration hooks and redirect URI patterns.",
        "Verify script execution environment (bash 5+, jq, curl, kubectl) in local environment and CI.",
        "Draft preflight audit document in docs/signalloom/slea-p3-preflight.md with automation architecture."
    ],
    deliverables=[
        "docs/signalloom/slea-p3-preflight.md detailing Tailscale CLI flags, Envoy HTTPRoute seams, and mock harness.",
        "Tailscale mock harness contract and specification for testing in CI environments.",
        "Envoy Gateway API HTTPRoute template draft for sl-eap-HASH subdomains.",
        "Errata block appended for SLEA-P3-PRE in proposal markdown."
    ],
    tests=[
        "bash -c \"tailscale version 2>/dev/null || echo 'Tailscale binary not present; mock mode required'\"",
        "test -f docs/signalloom/slea-p3-preflight.md",
        "git status --porcelain"
    ],
    evidence=[
        "docs/signalloom/slea-p3-preflight.md documenting all verified toolchains and CRD versions.",
        "Captured test output showing clean preflight probe execution.",
        "Errata block appended for SLEA-P3-PRE with status=pass."
    ],
    failures=[
        "Assuming Tailscale daemon is running locally without providing a robust mock fallback for development and CI.",
        "Using deprecated tailscale funnel flags that have been superseded in recent Tailscale releases.",
        "Failing to check Envoy HTTPRoute CRD compatibility leading to manifest rejection."
    ]
)

# P3-1: L implementation (>=700w, >=50l, >=6d, >=5t)
RAW_SPECS["P3-1"] = make_spec(
    "P3-1", "L", "implementation",
    obj=(
        "Build the Tailscale EAP dynamic routing script in scripts/eap/tailscale-eap-env.sh. Implement subcommands: "
        "'hash' to compute the customer hash for a given company name; 'provision' to register a new tailnet node with "
        "hostname sl-eap-{hash}; 'serve' to configure Tailscale Serve proxying incoming traffic on port 443 to the local "
        "Envoy Ingress Gateway port; 'funnel' to expose public UAT access via ts.net when requested; 'status' to inspect "
        "the node's mesh IP and active serve status; and 'teardown' to cleanly reset serve configuration, log out the "
        "tailnet node, and release resources. Implement TAILSCALE_MOCK=1 mode allowing full deterministic execution "
        "and testing without requiring a live Tailscale daemon. Write comprehensive BATS / shell test suite in "
        "scripts/eap/test_tailscale_eap_env.sh."
    ),
    approach=[
        "Create scripts/eap/tailscale-eap-env.sh with strict bash flags (set -euo pipefail).",
        "Implement argument parsing for commands: hash, provision, serve, funnel, status, teardown, and help.",
        "Implement hash command matching canonical derive_customer_hash logic (SHA-256 with salt, 8-char hex).",
        "Implement TAILSCALE_MOCK=1 detection simulating tailscale up, serve, and status commands with state files.",
        "In provision, run tailscale up --authkey=$TAILSCALE_AUTH_KEY --hostname=sl-eap-$HASH --accept-dns=false.",
        "In serve, configure tailscale serve https / http://127.0.0.1:8080 or Envoy Gateway port.",
        "In funnel, configure tailscale funnel 443 on when --funnel flag is provided.",
        "In status, parse and display JSON status including IPv4, IPv6, MagicDNS FQDN, and serve backends.",
        "In teardown, execute tailscale serve reset, tailscale funnel reset, and tailscale logout idempotently.",
        "Create scripts/eap/test_tailscale_eap_env.sh testing all subcommands under TAILSCALE_MOCK=1.",
        "Verify kurasi vector: 'tailscale-eap-env.sh hash kurasi' prints '6f82ad81' and hostname 'sl-eap-6f82ad81'.",
        "Document script CLI syntax, environment variables, and mock harness in docs/signalloom/slea-p3-tailscale-script.md."
    ],
    deliverables=[
        "Production-grade CLI automation script in scripts/eap/tailscale-eap-env.sh with complete subcommand suite.",
        "TAILSCALE_MOCK=1 mock engine enabling deterministic local and CI verification without root privileges.",
        "Comprehensive shell test suite in scripts/eap/test_tailscale_eap_env.sh verifying all CLI subcommands.",
        "Kurasi hash verification check in test script asserting 6f82ad81 output.",
        "docs/signalloom/slea-p3-tailscale-script.md detailing CLI usage, environment variables, and operational runbooks.",
        "Append-only errata entry for SLEA-P3-1 in proposal markdown."
    ],
    tests=[
        "bash scripts/eap/test_tailscale_eap_env.sh -k test_hash_kurasi",
        "bash scripts/eap/test_tailscale_eap_env.sh -k test_mock_provision",
        "bash scripts/eap/test_tailscale_eap_env.sh -k test_mock_serve",
        "bash scripts/eap/test_tailscale_eap_env.sh -k test_mock_status",
        "bash scripts/eap/test_tailscale_eap_env.sh -k test_mock_teardown",
        "bash scripts/eap/test_tailscale_eap_env.sh"
    ],
    evidence=[
        "Captured test output showing 100% pass across all shell test suite assertions.",
        "Execution trace of tailscale-eap-env.sh hash kurasi outputting 6f82ad81.",
        "docs/signalloom/slea-p3-tailscale-script.md with complete CLI documentation.",
        "Errata block appended for SLEA-P3-1 with status=pass."
    ],
    failures=[
        "Failing to pass --accept-dns=false causing Tailscale to overwrite host /etc/resolv.conf.",
        "Failing to clean up temporary mock state files in /tmp between test runs.",
        "Non-idempotent teardown exiting with error code when node is already logged out.",
        "Missing executable permission bit (+x) on scripts/eap/tailscale-eap-env.sh.",
        "Unquoted shell variables causing word splitting or glob expansion vulnerabilities."
    ]
)

# P3-2: L implementation (>=700w, >=50l, >=6d, >=5t)
RAW_SPECS["P3-2"] = make_spec(
    "P3-2", "L", "implementation",
    obj=(
        "Implement multi-tenant Envoy Ingress HTTPRoute templates and Dex OIDC redirect origin reconciler for "
        "dynamic EAP environments. Author d2-infra/components/ingress/eap-httproute-template.yaml defining "
        "Gateway API HTTPRoute rules matching hostnames sl-eap-{hash}.tailscale and sl-eap-{hash}.ts.net, "
        "routing requests to the appropriate tenant namespace or shared gateway service. Implement dynamic "
        "Dex redirect URI management allowing authorized OIDC callbacks from dynamic EAP domains without requiring "
        "manual Dex restarts. Author helper reconciler script scripts/eap/reconcile-eap-ingress.sh to apply and "
        "delete HTTPRoutes dynamically upon environment provisioning and teardown. Write manifest validation and "
        "routing conformance tests."
    ),
    approach=[
        "Author d2-infra/components/ingress/eap-httproute-template.yaml using Gateway API gateway.networking.k8s.io/v1.",
        "Define HTTPRoute spec with hostnames: ['sl-eap-${EAP_HASH}.tailscale', 'sl-eap-${EAP_HASH}.ts.net'].",
        "Configure route rules routing / to frontend service and /api/ to backend service with header rewrites.",
        "Implement Dex OIDC redirect URI reconciler adding https://sl-eap-${EAP_HASH}.tailscale/auth/callback to allowed list.",
        "Author scripts/eap/reconcile-eap-ingress.sh with commands: apply-route, delete-route, apply-dex-origin, delete-dex-origin.",
        "In reconcile-eap-ingress.sh, support DRY_RUN=1 and KUBECTL_MOCK=1 modes for testing without live cluster.",
        "Ensure route application and deletion are fully idempotent.",
        "Write test suite in scripts/eap/test_reconcile_eap_ingress.sh testing manifest rendering and kubectl operations.",
        "Validate rendered manifests against Gateway API and Kubernetes schemas using kubeconform if available.",
        "Document HTTPRoute architecture, Dex leasing protocol, and network policies in docs/signalloom/slea-p3-ingress-routing.md."
    ],
    deliverables=[
        "d2-infra/components/ingress/eap-httproute-template.yaml defining multi-tenant HTTPRoute rules.",
        "scripts/eap/reconcile-eap-ingress.sh automation script for dynamic route and Dex origin reconciliation.",
        "scripts/eap/test_reconcile_eap_ingress.sh testing manifest rendering and idempotency.",
        "Rendered HTTPRoute manifest fixture for customer 'kurasi' (sl-eap-6f82ad81).",
        "Dex OIDC callback origin leasing integration helper.",
        "docs/signalloom/slea-p3-ingress-routing.md documenting routing topology and security boundaries.",
        "Append-only errata entry for SLEA-P3-2 in proposal markdown."
    ],
    tests=[
        "bash scripts/eap/test_reconcile_eap_ingress.sh -k test_render_kurasi_route",
        "bash scripts/eap/test_reconcile_eap_ingress.sh -k test_apply_route_mock",
        "bash scripts/eap/test_reconcile_eap_ingress.sh -k test_delete_route_mock",
        "bash scripts/eap/test_reconcile_eap_ingress.sh -k test_dex_origin_lease",
        "bash scripts/eap/test_reconcile_eap_ingress.sh"
    ],
    evidence=[
        "Captured test output showing 100% pass across ingress reconciliation test cases.",
        "Rendered YAML manifest proving valid Envoy HTTPRoute configuration for sl-eap-6f82ad81.",
        "docs/signalloom/slea-p3-ingress-routing.md with complete routing architecture diagrams.",
        "Errata block appended for SLEA-P3-2 with status=pass."
    ],
    failures=[
        "Hardcoding namespace names causing cross-tenant routing pollution.",
        "Failing to clean up HTTPRoute CRs upon environment teardown leaving orphaned routing rules in Envoy.",
        "OIDC callback URL mismatch causing Dex authentication failures for EAP users.",
        "Missing Gateway API CRD definitions causing kubectl apply to reject HTTPRoute manifests.",
        "Unquoted environment variables in template substitution resulting in invalid YAML indentation."
    ]
)

# P3-GOV: M governor (>=450w, >=35l, >=5d, tests exempt)
RAW_SPECS["P3-GOV"] = make_spec(
    "P3-GOV", "M", "governor",
    obj=(
        "Phase 3 Governor Certification: independently verify Tailscale EAP automation scripts, Envoy Ingress HTTPRoute "
        "templates, and Dex dynamic redirect origin reconciliation. Audit script error handling under failure conditions "
        "(daemon offline, network unreachable, invalid auth keys), verify that kurasi environment routing manifests render "
        "with correct hostnames (sl-eap-6f82ad81), and test teardown cleanup to ensure zero orphaned routes or leaked nodes. "
        "Reconcile Phase 3 deliverables into the integration branch, run all shell and Python test suites, author certification "
        "documentation, and certify readiness for Phase 4 end-to-end acceptance testing."
    ),
    approach=[
        "Review git diff of all Phase 3 scripts, manifests, and documentation.",
        "Execute scripts/eap/test_tailscale_eap_env.sh and scripts/eap/test_reconcile_eap_ingress.sh in full.",
        "Execute kurasi routing dry-run asserting that rendered HTTPRoute exactly matches sl-eap-6f82ad81.",
        "Audit shell scripts for safe error handling, quoting, and absence of hardcoded secrets.",
        "Verify kanban board doctor status ensuring zero graph anomalies or orphaned cards.",
        "Author Phase 3 certification report in docs/signalloom/slea-p3-certification.md.",
        "Append qualified Phase 3 completion errata block to proposal markdown."
    ],
    deliverables=[
        "docs/signalloom/slea-p3-certification.md certifying Phase 3 Tailscale and Envoy Ingress automation.",
        "Automated governor verification script executing end-to-end dry-run for kurasi routing.",
        "Captured test output demonstrating 100% pass across all Phase 3 test suites.",
        "Clean kanban-check doctor verification report.",
        "Phase 3 Governor errata block appended to proposal markdown with status=pass."
    ],
    tests=[
        "bash scripts/eap/test_tailscale_eap_env.sh",
        "bash scripts/eap/test_reconcile_eap_ingress.sh",
        "~/.claude/skills/ajm-auto-kanban/Tools/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLEA"
    ],
    evidence=[
        "docs/signalloom/slea-p3-certification.md signed with verification artifacts.",
        "Green test run outputs demonstrating zero defects across shell automation suites.",
        "Clean doctor output verifying healthy board state.",
        "Errata block appended for SLEA-P3-GOV with status=pass."
    ],
    failures=[
        "Certifying Phase 3 while any shell script fails shellcheck or exhibits unhandled exit codes.",
        "Allowing temporary files or mock sockets to persist in /tmp after test completion.",
        "Merging unvalidated manifests into the integration branch.",
        "Failing to test teardown idempotency leading to resource leaks."
    ]
)

# P4-PRE: S preflight (>=250w, >=20l, >=4d, tests exempt)
RAW_SPECS["P4-PRE"] = make_spec(
    "P4-PRE", "S", "preflight",
    obj=(
        "Audit tenant namespace templates, Flux ResourceSets, and teardown cleanup guards for on-demand EAP environments. "
        "Verify how tenant namespaces (e.g. eap-6f82ad81) are isolated using Kubernetes NetworkPolicies, verify resource "
        "quotas preventing CPU/memory exhaustion, and check teardown garbage collection rules to guarantee complete removal "
        "of all ephemeral resources upon environment expiration."
    ),
    approach=[
        "Inspect d2-osramp-fleet/ tenant definitions and ResourceSet templates.",
        "Audit NetworkPolicy templates to ensure strict tenant isolation (no cross-namespace traffic between EAP environments).",
        "Review ResourceQuota and LimitRange configurations to prevent rogue workloads from consuming cluster resources.",
        "Verify namespace finalizer and deletion semantics under automated teardown scripts.",
        "Draft preflight audit report in docs/signalloom/slea-p4-preflight.md with tenant isolation specifications."
    ],
    deliverables=[
        "docs/signalloom/slea-p4-preflight.md detailing tenant namespace isolation, ResourceSets, and teardown guards.",
        "Tenant NetworkPolicy template enforcing ingress/egress boundaries.",
        "ResourceQuota specification sizing EAP demo environments appropriately.",
        "Errata block appended for SLEA-P4-PRE in proposal markdown."
    ],
    tests=[
        "test -f docs/signalloom/slea-p4-preflight.md",
        "pytest tests/test_environment_routing.py -v",
        "git status --porcelain"
    ],
    evidence=[
        "docs/signalloom/slea-p4-preflight.md documenting all tenant isolation specifications.",
        "Captured test output showing clean preflight execution.",
        "Errata block appended for SLEA-P4-PRE with status=pass."
    ],
    failures=[
        "Omitting default-deny NetworkPolicies allowing tenant environments to communicate across boundaries.",
        "Setting excessively high ResourceQuotas enabling denial of service on shared cluster resources.",
        "Failing to handle namespace termination finalizers causing namespaces to stick in Terminating state."
    ]
)

# P4-1: L implementation (>=700w, >=50l, >=6d, >=5t)
RAW_SPECS["P4-1"] = make_spec(
    "P4-1", "L", "implementation",
    obj=(
        "Implement on-demand demo/UAT namespace bootstrapper and automated teardown garbage collector in "
        "scripts/eap/eap-namespace-manager.sh and fe-signalloom/src/environment_reconciler.py. Build automated "
        "namespace creation logic that generates namespace eap-{hash}, applies tenant ResourceQuotas, NetworkPolicies, "
        "and deploys the Signal Loom demo application stack. Implement background reconciler loop that continuously "
        "monitors active environments, identifies environments whose expires_at timestamp has passed, triggers "
        "Tailscale teardown, removes Envoy HTTPRoutes, releases Dex OIDC origins, and deletes the tenant namespace. "
        "Support dry-run and mock execution modes. Write comprehensive unit and integration tests verifying "
        "reconciler correctness, sweep intervals, and graceful resource termination."
    ),
    approach=[
        "Create scripts/eap/eap-namespace-manager.sh with subcommands: create-ns, delete-ns, status-ns.",
        "In create-ns, render and apply tenant namespace manifest with labels: eap-hash=$HASH, customer=$COMPANY.",
        "Apply tenant NetworkPolicies restricting ingress to Envoy Gateway and egress to required cluster DNS.",
        "Implement fe-signalloom/src/environment_reconciler.py with EnvironmentReconciler class.",
        "In EnvironmentReconciler, implement async sweep_expired_environments() method executing every 60 seconds.",
        "For each expired environment, call teardown handler: reset Tailscale serve/node, remove HTTPRoute, delete namespace.",
        "Record transition to TERMINATED state in EnvironmentRegistry with reason='TTL expired'.",
        "Ensure reconciler handles external exceptions gracefully without terminating the background loop.",
        "Write comprehensive test suite in fe-signalloom/src/tests/test_environment_reconciler.py.",
        "Test automatic expiration detection by mocking time progression past expires_at.",
        "Test graceful error recovery when namespace deletion fails or times out.",
        "Document namespace provisioning architecture and reconciler mechanics in docs/signalloom/slea-p4-reconciler.md."
    ],
    deliverables=[
        "Namespace lifecycle automation script in scripts/eap/eap-namespace-manager.sh.",
        "fe-signalloom/src/environment_reconciler.py implementing background TTL expiration sweeper.",
        "Comprehensive test suite in fe-signalloom/src/tests/test_environment_reconciler.py.",
        "Graceful teardown integration testing Tailscale, HTTPRoute, and namespace deletion orchestration.",
        "Tenant NetworkPolicy and ResourceQuota manifest templates for EAP environments.",
        "docs/signalloom/slea-p4-reconciler.md detailing reconciler architecture and recovery procedures.",
        "Append-only errata entry for SLEA-P4-1 in proposal markdown."
    ],
    tests=[
        "pytest tests/test_environment_reconciler.py -k test_reconciler_detects_expired -v",
        "pytest tests/test_environment_reconciler.py -k test_reconciler_executes_teardown -v",
        "pytest tests/test_environment_reconciler.py -k test_reconciler_error_recovery -v",
        "pytest tests/test_environment_reconciler.py -k test_namespace_manifest_rendering -v",
        "pytest tests/test_environment_reconciler.py -v"
    ],
    evidence=[
        "Captured pytest execution log demonstrating 100% pass across reconciler test suite.",
        "Execution trace showing automated detection of expired test environment and successful sweep.",
        "docs/signalloom/slea-p4-reconciler.md with complete reconciler architecture documentation.",
        "Errata block appended for SLEA-P4-1 with status=pass."
    ],
    failures=[
        "Reconciler loop crashing on unexpected exception and failing to restart.",
        "Deleting wrong namespaces due to improper label matching or unverified hash parameters.",
        "Race condition between manual teardown request and automated TTL expiration sweep.",
        "Failing to release Tailscale nodes when namespace deletion succeeds leaving zombie nodes.",
        "Blocking the async event loop with synchronous subprocess calls."
    ]
)

# P4-2: L implementation (>=700w, >=50l, >=6d, >=5t)
RAW_SPECS["P4-2"] = make_spec(
    "P4-2", "L", "implementation",
    obj=(
        "Build comprehensive end-to-end acceptance test suite for customer 'kurasi' EAP environment lifecycle in "
        "fe-signalloom/src/tests/test_kurasi_eap_lifecycle.py. Validate the entire customer journey from initial "
        "provisioning to domain resolution, health probing, TTL extension, and automated teardown. Assert that the "
        "initial provisioning request for company 'kurasi' yields HTTP 201 Created, hash '6f82ad81', internal mesh "
        "URL 'https://sl-eap-6f82ad81.tailscale', and external MagicDNS FQDN 'https://sl-eap-6f82ad81.ts.net'. Assert that "
        "resolving domain by company name or hash returns identical URLs. Test TTL extension by adding 120 minutes, "
        "verifying updated expires_at. Test teardown request asserting state progression to TERMINATED. Verify complete "
        "idempotency, clean state reset, and zero orphaned test artifacts."
    ),
    approach=[
        "Create fe-signalloom/src/tests/test_kurasi_eap_lifecycle.py with pytest-asyncio and FastAPI TestClient.",
        "Implement test_kurasi_full_lifecycle executing sequential steps: provision -> resolve -> probe -> extend -> teardown.",
        "Step 1 (Provision): POST /api/v1/environments/provision with company_name='kurasi', ttl_minutes=180.",
        "Verify Step 1: HTTP 201 Created, customer_hash=='6f82ad81', internal_mesh_url=='https://sl-eap-6f82ad81.tailscale'.",
        "Step 2 (Resolve Domain): POST /api/v1/environments/resolve-domain with company_name='kurasi'.",
        "Verify Step 2: HTTP 200 OK, identical URLs returned matching Step 1.",
        "Step 3 (Get Status): GET /api/v1/environments/{id} asserting state is PROVISIONING or READY.",
        "Step 4 (Extend TTL): POST /api/v1/environments/{id}/extend with additional_minutes=120.",
        "Verify Step 4: HTTP 200 OK, new expires_at is exactly 120 minutes later than previous expiration.",
        "Step 5 (Teardown): POST /api/v1/environments/{id}/teardown with reason='Acceptance test completed'.",
        "Verify Step 5: HTTP 200 OK, state is TERMINATED.",
        "Step 6 (Idempotency): Repeated POST /teardown returns 200 OK without errors.",
        "Write acceptance report in docs/signalloom/slea-p4-acceptance-report.md documenting complete lifecycle run."
    ],
    deliverables=[
        "End-to-end acceptance test suite in fe-signalloom/src/tests/test_kurasi_eap_lifecycle.py.",
        "Automated kurasi canonical verification fixture asserting hash 6f82ad81 across all layers.",
        "Complete lifecycle execution transcript capturing request and response bodies for every step.",
        "Idempotent teardown and cleanup verification test.",
        "docs/signalloom/slea-p4-acceptance-report.md detailing test results and verification logs.",
        "Append-only errata entry for SLEA-P4-2 in proposal markdown."
    ],
    tests=[
        "pytest tests/test_kurasi_eap_lifecycle.py -k test_kurasi_full_lifecycle -v",
        "pytest tests/test_kurasi_eap_lifecycle.py -k test_kurasi_canonical_hash_strict -v",
        "pytest tests/test_kurasi_eap_lifecycle.py -k test_kurasi_extend_and_teardown -v",
        "pytest tests/test_kurasi_eap_lifecycle.py -k test_kurasi_teardown_idempotency -v",
        "pytest tests/test_kurasi_eap_lifecycle.py -v",
        "pytest tests/ -v"
    ],
    evidence=[
        "Captured pytest execution log demonstrating 100% pass on kurasi end-to-end acceptance suite.",
        "Full JSON trace of kurasi environment lifecycle states from provision to termination.",
        "docs/signalloom/slea-p4-acceptance-report.md with complete test output citations.",
        "Errata block appended for SLEA-P4-2 with status=pass."
    ],
    failures=[
        "Flaky async test timing during TTL countdown or expiration assertions.",
        "Failing to clean up temporary test database entries leaving stale state between test runs.",
        "Asserting non-deterministic timestamps rather than relative deltas.",
        "Failing to assert exact match on canonical hash 6f82ad81.",
        "Leaving mock files in /tmp after acceptance test execution."
    ]
)

# P4-GOV: L governor (>=700w, >=50l, >=6d, tests exempt)
RAW_SPECS["P4-GOV"] = make_spec(
    "P4-GOV", "L", "governor",
    obj=(
        "Final Mission Certification for SLEA: execute comprehensive independent verification of the entire on-demand "
        "EAP environment routing, Tailscale provisioning engine, and customer 'kurasi' lifecycle. Audit code quality, test "
        "coverage, documentation completeness, API wire contracts, and architectural compliance across the entire monorepo. "
        "Confirm that 100% of tests pass across all Python, shell, and acceptance suites with zero regressions. Verify that "
        "the kanban board doctor check passes with zero defects. Author the final mission certification report in "
        "docs/signalloom/slea-mission-complete.md, append the final mission certification errata block, and seal the SLEA "
        "release for production deployment."
    ),
    approach=[
        "Checkout integration branch integration/slea-v0.1.0 or inspect clean git status.",
        "Execute the entire test suite in fe-signalloom: unit tests, API tests, lifecycle tests, and reconciler tests.",
        "Execute kurasi acceptance suite in test_kurasi_eap_lifecycle.py asserting 100% green status.",
        "Execute shell test suites: test_tailscale_eap_env.sh and test_reconcile_eap_ingress.sh.",
        "Audit docs/ to confirm all required documentation files exist, are well-linked, and contain no broken references.",
        "Run scripts/kanban-check.sh doctor --shortcode SLEA to confirm zero unresolved defects or orphaned cards.",
        "Verify that kurasi canonical hash is strictly 6f82ad81 and mesh URL is https://sl-eap-6f82ad81.tailscale.",
        "Author final mission certification document in docs/signalloom/slea-mission-complete.md.",
        "Append final Phase 4 Governor errata block to proposal markdown marking SLEA mission fully certified."
    ],
    deliverables=[
        "Final mission certification document in docs/signalloom/slea-mission-complete.md.",
        "Comprehensive green test execution transcript covering Python, shell, and acceptance test suites.",
        "Clean kanban-check doctor verification report proving zero board anomalies.",
        "Final errata block appended to proposal markdown marking Phase 4 certified.",
        "Release readiness checklist verifying all acceptance criteria have been satisfied.",
        "Final integration branch merge commit sealing the SLEA v0.1.0 release.",
        "docs/signalloom/slea-architecture-summary.md summarizing the new EAP provisioning capabilities."
    ],
    tests=[
        "pytest tests/test_kurasi_eap_lifecycle.py -v",
        "pytest tests/test_environment_routing.py tests/test_environment_api.py -v",
        "bash scripts/eap/test_tailscale_eap_env.sh",
        "bash scripts/eap/test_reconcile_eap_ingress.sh",
        "~/.claude/skills/ajm-auto-kanban/Tools/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLEA"
    ],
    evidence=[
        "docs/signalloom/slea-mission-complete.md detailing full mission certification.",
        "Captured test logs demonstrating 100% green status across all suites.",
        "Clean doctor output verifying zero defects.",
        "Final errata block appended for SLEA-P4-GOV with status=pass."
    ],
    failures=[
        "Declaring mission complete while any acceptance test is mocked rather than fully executed.",
        "Leaving uncommitted temporary files or dirty git worktree state.",
        "Failing to certify canonical kurasi vector across all operational layers.",
        "Overlooking broken links or incomplete documentation in docs/signalloom/."
    ]
)

def main():
    print("Validating and generating council-grade card specifications for SLEA...\n")
    all_ok = True
    for lid, card_spec in RAW_SPECS.items():
        # Determine band & role
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

        # Write to disk
        spec_payload = {
            "specCacheVersion": 1,
            "shortcode": "SLEA",
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

    print(f"\nSUCCESS: All {len(RAW_SPECS)} SLEA card specifications generated and 100% compliant with SPEC_FLOORS!")

if __name__ == "__main__":
    main()
