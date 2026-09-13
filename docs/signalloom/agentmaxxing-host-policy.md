# AgentMaxxing Linux host policy v1

- **Status:** frozen for AMXO-P1-2
- **Profile:** `agentmaxxing-linux-v1`
- **Sandbox:** nono `0.73.0` on Linux with Landlock
- **Approver:** Andrew Martin
- **Approval provenance:** direct `AMXO-P1-2 task contract`, 2026-09-12
- **Machine-readable policy:** `d2-signalloom/governance/fixtures/agentmaxxing-host-policy.v1.json`

This is the configuration specification for the first AgentMaxxing external
Linux agent. It defines what the host process may access and what Signal Loom
may export. It does not claim partner acceptance, production readiness, host
trust, or complete observation. The Go `signal-ingest/collectors/agentnono`
package remains the only nono session-integrity authority.

## Attributable runtime identity

| Field | Frozen value |
| :--- | :--- |
| Host owner | AgentMaxxing Incorporated |
| Linux service account | `agentmaxxing-sensor` |
| systemd unit | `agentmaxxing-agent.service` |
| Tenant | `tenant-agentmaxxing` |
| Agent | `agentmaxxing-linux-001` |
| Host | `amx-host-001` |

The service starts only through nono `0.73.0`. Landlock and the nono network
proxy are mandatory; failure to install either boundary prevents startup.
Evidence upload identity binds to this pre-registered tenant-agent-host tuple.
Request-supplied tenant, agent, or host fields never override the authenticated
server-side binding.

## Approved filesystem roots

The profile does not accept environment expansion, home-directory shorthand,
globs, relative paths, or caller-added roots.

### Readable

| Root ID | Absolute path | Artifact hashing |
| :--- | :--- | :--- |
| `agent-install` | `/opt/agentmaxxing` | prohibited |
| `system-trust` | `/etc/ssl/certs` | prohibited |
| `customer-input` | `/srv/agentmaxxing/input` | prohibited |

Read-only input digests are deliberately unobserved. This prevents a content
digest from becoming a durable identifier for customer input.

### Writable

| Root ID | Absolute path | Artifact hashing |
| :--- | :--- | :--- |
| `agent-work` | `/var/lib/agentmaxxing/work` | eligible |
| `agent-output` | `/var/lib/agentmaxxing/output` | eligible |
| `nono-audit` | `/var/lib/agentmaxxing/audit` | prohibited |

Eligibility is not permission to hash. A file must also pass every descriptor,
identity, type, mount, size, rate, and mutation check below.

## Approved network destinations

Only exact destination IDs are exported. Raw DNS names, URLs, request paths,
query strings, headers, errors, and payloads remain on the host.

| Destination ID | Exact DNS name | Transport | Port | TLS |
| :--- | :--- | :--- | ---: | :--- |
| `signal-loom-ingest` | `signal-ingest.signalloom.controlplane.io` | TCP | 443 | required |
| `agentmaxxing-api` | `api.agentmaxxing.com` | TCP | 443 | required |

No wildcard destination, IP range, alternate port, plaintext fallback, or
direct DNS exception is approved. Destination matching occurs inside nono's
proxy boundary; denial is reported by destination ID only.

## Descriptor-relative artifact access

At service startup, the sensor opens and pins each approved root descriptor.
Each candidate is opened relative to its pinned root through `openat2()` using
all three flags:

- `RESOLVE_BENEATH`
- `RESOLVE_NO_SYMLINKS`
- `RESOLVE_NO_XDEV`

Before reading bytes, `fstat()` and `statx(STATX_MNT_ID)` must establish that
the candidate is a regular file, has exactly one hard link, and remains on the
approved root mount. The sensor snapshots inode, mount ID, link count, size,
`mtime_ns`, and `ctime_ns`. It hashes through that validated descriptor only.
It repeats the complete snapshot after reading and discards the digest if any
value changed. A string path is never reopened after validation.

## Hashing limits

| Limit | Frozen value |
| :--- | ---: |
| Algorithm | SHA-256 |
| Maximum file size | 16,777,216 bytes (16 MiB) |
| Maximum files | 120 per 60-second window |
| Maximum bytes | 67,108,864 bytes (64 MiB) per 60-second window |

The limits apply before bytes are read. Exhausted or oversized candidates are
`unobserved`; they are never labelled unchanged, compliant, or verified. Rate
counters use a monotonic 60-second window, and exported telemetry is ordered by
`(session_id, sequence)` for deterministic replay.

## Closed export allowlist

The producer constructs a new object from these safe fields before persistence.
Unknown input fields are ignored rather than copied and redacted later.
`additionalProperties: false` closes every object in the export schema.

Common fields:

- `schema_version`, `session_id`, `sequence`, `observed_at`
- `source`, `evidence_type`, `observation_state`, `integrity_state`
- server-bound `tenant_id`, `agent_id`, `host_id`

Type-specific attributes:

| Evidence type | Allowed attributes |
| :--- | :--- |
| Process | `health_state`, `cpu_time_ms`, `resident_memory_bytes`, `exit_code`, `restart_count` |
| Artifact | `artifact_id`, `root_id`, `sha256`, `size_bytes`, `mtime_ns` |
| Network | `destination_id`, `decision` |
| Collection limit | `reason_code`, `max_file_size_bytes`, `max_files_per_window`, `max_bytes_per_window`, `window_seconds` |

`artifact_id` is an opaque `hmac-sha256:` token derived by a later host card;
it is not a raw or reversible path. The schemas do not permit raw nono records,
commands, paths, URLs, errors, file contents, process memory contents, streamed
payload digests, streamed payload contents, or network payload contents.

## Explicit observation limits

The following remain `unobserved` by contract:

- read-only input-file digests;
- file contents;
- process memory contents;
- in-memory synthesis contents;
- streamed payload digests;
- streamed payload contents; and
- network payload contents.

`observed`, `denied`, and `unobserved` describe collection outcomes.
`integrity-verified` describes only verification of supplied evidence. These
axes are independent: an integrity-verified session can still contain an
unobserved boundary, and integrity never implies completeness, compliance, or
a trustworthy host.

## Retention, deletion, and removal

| Decision | Frozen value |
| :--- | :--- |
| Evidence retention | 30 days from ingestion |
| Deletion deadline | Seven calendar days after a verified trigger |
| Retention owner | ControlPlane Signal Loom Operations |
| Deletion owner | ControlPlane Signal Loom Operations |
| Host unenrollment owner | AgentMaxxing Platform Engineering |
| Trigger | Verified tenant request or host unenrollment |

Host unenrollment revokes future upload authority independently from operator
identity. Deletion covers exported evidence only; prohibited payload data was
never collected and therefore cannot be represented as deleted evidence.

## P1-2 enforcement mapping

1. Runtime isolation: nono version, Landlock, pinned roots, and exact proxy
   destinations are fail-closed policy fields.
2. Attributable identity: exported identity comes only from the registered
   server-side tenant-agent-host binding.
3. Deterministic telemetry: fixed field ordering, sequence numbers, closed
   per-type attributes, and explicit source labels make output reproducible.
4. Privacy preservation: filtering constructs a fresh allowlisted object before
   any later persistence seam and classifies missing evidence as unobserved.
