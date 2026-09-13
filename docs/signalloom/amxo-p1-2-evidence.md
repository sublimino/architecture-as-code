# AMXO-P1-2 approved host-policy evidence

- **Date:** 2026-09-12
- **Logical task:** P1-2 — Record approved host policy privacy limits and lifecycle decisions
- **Approver:** Andrew Martin
- **Approval provenance:** direct AMXO-P1-2 task contract
- **Policy version:** `amxo-host-policy-v1` (`1.0.0`)
- **Runtime profile:** `agentmaxxing-linux-v1`, nono `0.73.0`

## Scope and authority

This report freezes the Phase 1 contract consumed by later host and ingestion
cards. Andrew Martin supplied the task contract that explicitly directs P1-2 to
freeze canonical values and author the corresponding schemas, fixtures, tests,
evidence, and proof. This is the named approval provenance for these choices;
it is not represented as a separate AgentMaxxing partner attestation.

The P1-2 implementation defines policy validation and a pure export-filtering
contract for later use at the persistence boundary. It is not wired into the
current ingestion route; that integration remains assigned to P5-3. It
deliberately does not add another nono audit-chain verifier,
modify a route registry, create a database migration, deploy a host component,
or contact external infrastructure.

## Frozen approved limits

### Runtime identity

| Field | Approved value |
| :--- | :--- |
| Host owner | AgentMaxxing Incorporated |
| Service account | `agentmaxxing-sensor` |
| systemd unit | `agentmaxxing-agent.service` |
| Tenant-agent-host binding | `tenant-agentmaxxing` / `agentmaxxing-linux-001` / `amx-host-001` |

### Filesystem

| Access | Root ID | Absolute root | Hash eligibility |
| :--- | :--- | :--- | :--- |
| Read | `agent-install` | `/opt/agentmaxxing` | no |
| Read | `system-trust` | `/etc/ssl/certs` | no |
| Read | `customer-input` | `/srv/agentmaxxing/input` | no |
| Write | `agent-work` | `/var/lib/agentmaxxing/work` | yes |
| Write | `agent-output` | `/var/lib/agentmaxxing/output` | yes |
| Write | `nono-audit` | `/var/lib/agentmaxxing/audit` | no |

Artifact access is descriptor-relative from service-lifetime pinned root file
descriptors. It requires `openat2()` with `RESOLVE_BENEATH`,
`RESOLVE_NO_SYMLINKS`, and `RESOLVE_NO_XDEV`. A candidate must be a regular
single-link file on the approved mount. Inode, mount ID, link count, size,
`mtime_ns`, and `ctime_ns` are compared before and after reading through the
same validated descriptor.

### Network

| Destination ID | Exact tuple | TLS |
| :--- | :--- | :--- |
| `signal-loom-ingest` | `signal-ingest.signalloom.controlplane.io`, TCP, 443 | required |
| `agentmaxxing-api` | `api.agentmaxxing.com`, TCP, 443 | required |

The policy admits no wildcard host, network range, alternate port, plaintext
fallback, raw URL export, or caller-provided destination.

### Artifact hashing

| Control | Approved limit |
| :--- | ---: |
| Algorithm | SHA-256 |
| Maximum candidate file | 16,777,216 bytes |
| Maximum candidates | 120 per 60 seconds |
| Maximum bytes | 67,108,864 per 60 seconds |

Oversized and rate-exhausted candidates are `unobserved`, not unchanged,
compliant, or verified.

### Lifecycle

| Decision | Approved value |
| :--- | :--- |
| Evidence retention | 30 days from ingestion |
| Deletion deadline | Seven calendar days after verified trigger |
| Retention owner | ControlPlane Signal Loom Operations |
| Deletion owner | ControlPlane Signal Loom Operations |
| Host unenrollment owner | AgentMaxxing Platform Engineering |
| Deletion trigger | Verified tenant request or host unenrollment |

## Privacy and export boundary

The export schema permits only common attribution, sequencing, source,
observation, and integrity fields plus a closed type-specific attributes
object. The filter constructs a fresh output object before any later
persistence seam. Tenant, agent, and host identity come from the passed
server-side binding rather than raw host telemetry. The filter rejects an
identity that differs from the frozen registration, an artifact associated
with a non-hashable root, and collection-limit evidence not marked unobserved.

The following values are prohibited from export:

- raw nono records;
- commands;
- filesystem paths;
- URLs;
- raw errors;
- file contents;
- process memory contents;
- streamed payload digests;
- streamed payload contents; and
- network payload contents.

The following evidence is explicitly `unobserved`:

- read-only input-file digests;
- file contents;
- process memory contents;
- in-memory synthesis contents;
- streamed payload digests;
- streamed payload contents; and
- network payload contents.

Observation state and integrity state remain orthogonal. Tests demonstrate an
`integrity-verified` session whose absent field remains `unobserved`.

## Verification evidence

| Check | Result |
| :--- | :--- |
| Integration ancestry | PASS — `git merge-base --is-ancestor integration/agentmaxxing-onboarding-v0.1.0 HEAD`, exit 0 |
| Kernel capability | PASS — Linux `7.1.3+deb13-amd64`, Landlock ABI 9 |
| Focused required pytest | PASS — 1 selected, 1 passed, 14 deselected |
| P1-2 combined pytest | PASS — 37 passed |
| Canonical pinned unittest discovery | PASS — 22 tests, `OK` |
| Python compilation | PASS |
| Four JSON syntax checks | PASS |
| Draft 2020-12 schema validation | PASS — canonical policy and filtered export validate |
| Schema negative cases | PASS — added root, extra field, and partial attributes rejected |
| Staged diff whitespace gate | PASS — `git diff --cached --check` |
| Contract make probe | TOLERATED — target is not yet defined; required command used `|| true` |

The default host `python3` is Python 3.14 and lacks repository test-only
dependencies. Its first bare discovery attempt reported import errors. The
required discovery command was therefore rerun inside the repository's
documented Python 3.12 `uv` environment, with `pytest-asyncio`, `pytest-xdist`,
runtime requirements, and `PYTHONPATH` supplied. The exact inner
`python3 -m unittest discover -s d2-signalloom/apps/fe-signalloom/src/tests -p
'test_*.py'` invocation then exited 0 after 22 tests. No dependency was added to
the shipping image.

The missing `demo-agentmaxxing-contract-test` target is expected at this phase:
the proposal states the acceptance targets do not exist yet, and the card's
required probe explicitly tolerates this outcome. P1-2 did not modify the
shared Makefile composition root.

## Artifact map

| Artifact | Purpose |
| :--- | :--- |
| `docs/signalloom/agentmaxxing-host-policy.md` | Human-readable policy specification |
| `d2-signalloom/governance/schemas/agentmaxxing-host-policy.v1.json` | Closed policy schema |
| `d2-signalloom/governance/schemas/agentmaxxing-export.v1.json` | Closed field-level export schema |
| `d2-signalloom/governance/fixtures/agentmaxxing-host-policy.v1.json` | Canonical approved policy fixture |
| `d2-signalloom/governance/fixtures/agentmaxxing-raw-telemetry.v1.json` | Prohibited-field test fixture |
| `d2-signalloom/governance/verify_agentmaxxing_contract.py` | Executable Draft 2020-12 validation probe |
| `d2-signalloom/apps/fe-signalloom/src/agentmaxxing_host_policy.py` | Strict model and pre-persistence filter |
| `d2-signalloom/apps/fe-signalloom/src/tests/test_agentmaxxing_host_policy.py` | Policy, schema, filtering, and state tests |
| `d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py` | Required named privacy-boundary unit contract test |

The named test in `test_audit_ingest.py` is colocated with the future ingestion
seam; it does not claim that the current HTTP route invokes the filter.

No test contacted an external network or modified production, partner, board,
database, route, migration, manifest, or sibling-worktree state.
