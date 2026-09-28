# SLED teardown evidence format

`scripts/eap/verify_teardown_evidence.py` validates the structure and internal
consistency of a supplied teardown manifest. It performs no teardown and makes
no claim that supplied JSON is authentic. Live runtime collection remains a
separate required activity.

## Validation command

```bash
python3 scripts/eap/verify_teardown_evidence.py evidence.json \
  --expected-commit "$(git rev-parse HEAD)" \
  --max-age-seconds 3600
```

Use `--now 2026-09-28T02:30:00Z` for deterministic tests. Success exits `0`;
invalid or unavailable evidence exits `2`. Output is one JSON object containing
only controlled summary fields. Manifest values other than `run_id` and
`target_commit` are never copied into the report.

Pass `--expected-sha256 <hex>` to pin the exact manifest bytes a collector
produced. The success report carries `manifest_sha256` and `manifest_bytes`,
computed over the bytes that were parsed, not over whatever is on disk later.
A failure report carries `error_code` plus static `error_category` and
`error_detail` triage text. That text is keyed by code and never contains
manifest values.

## Descriptor-safe reading

The manifest is read through one file descriptor. The path is never resolved
twice, and the file size is never trusted as a proxy for the bytes read.

1. `os.lstat(path)` records the directory entry's `(st_dev, st_ino)`.
2. `os.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | O_NOCTTY)`
   refuses a terminal symlink and cannot block on a FIFO. A flag the platform
   lacks is treated as `0`.
3. `os.fstat(fd)` must report the same `(st_dev, st_ino)`, or the result is
   `manifest-path-raced`. It must also report a regular file, or the result is
   `manifest-not-regular`. Without `O_NOFOLLOW`, this comparison still rejects
   a symlink, because `lstat` describes the link and `fstat` describes its
   target.
4. Bytes are read from the descriptor up to a hard ceiling of
   `MAX_MANIFEST_BYTES + 1` (512 KiB + 1). Anything past 524,288 bytes raises
   `EvidenceSizeError` (`manifest-too-large`). The ceiling holds even if the
   file grows after `fstat`.
5. The descriptor is closed in a `finally` block on every path.
6. The bytes are decoded as strict UTF-8 and parsed with `json.loads`.
   Duplicate keys give `duplicate-json-key`. `NaN`, `Infinity`, invalid UTF-8,
   truncated or invalid JSON, integers over the interpreter's digit limit, and
   nesting deeper than 32 levels all give `malformed-json`, never a traceback.

A symlinked manifest gives `manifest-unavailable`, and its target is never
read. A FIFO, a device or a directory gives `manifest-not-regular` (or
`manifest-unavailable` where the open itself is refused).

## Version 1 manifest

The closed schema version is `sled-teardown-evidence/v1`. Unknown fields are
rejected, which prevents credentials, tokens, or arbitrary payloads from being
carried through this evidence channel.

```json
{
  "schema_version": "sled-teardown-evidence/v1",
  "run_id": "sled-run-20260928-alpha",
  "target_commit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "started_at": "2026-09-28T02:20:00Z",
  "finished_at": "2026-09-28T02:25:00Z",
  "fixture": {
    "kind": "synthetic",
    "tenant_kind": "synthetic",
    "fixture_id": "fixture-alpha",
    "tenant_id": "tenant-alpha",
    "expected_preinventory": {
      "drain_routes": ["expected-drain_routes"],
      "openbao": ["expected-openbao"],
      "spire_svid": ["expected-spire_svid"],
      "tailscale": ["expected-tailscale"],
      "namespace": ["expected-namespace"]
    }
  },
  "sentinel_fixture": {
    "kind": "synthetic",
    "tenant_kind": "synthetic",
    "fixture_id": "fixture-sentinel",
    "tenant_id": "tenant-sentinel",
    "expected_resource_ids": ["expected-sentinel-namespace"]
  },
  "before": {
    "observed_at": "2026-09-28T02:21:00Z",
    "planes": {
      "drain_routes": {"available": true, "permitted": true, "succeeded": true, "resources": []},
      "openbao": {"available": true, "permitted": true, "succeeded": true, "resources": []},
      "spire_svid": {"available": true, "permitted": true, "succeeded": true, "resources": []},
      "tailscale": {"available": true, "permitted": true, "succeeded": true, "resources": []},
      "namespace": {"available": true, "permitted": true, "succeeded": true, "resources": []}
    },
    "sentinel": {"available": true, "permitted": true, "succeeded": true, "resources": []}
  },
  "after": {
    "observed_at": "2026-09-28T02:24:00Z",
    "planes": {},
    "sentinel": {"available": true, "permitted": true, "succeeded": true, "resources": []}
  },
  "unverified_claims": {
    "cryptographic_backup_erasure": "UNVERIFIED",
    "kernel_payload_sanitisation": "UNVERIFIED"
  }
}
```

The abbreviated example shows field placement, not a valid positive fixture.
A valid `before` observation contains at least one concrete synthetic-fixture
resource in **each** required plane. Every resource contains only:

```json
{
  "resource_id": "expected-tailscale",
  "resource_type": "tailscale",
  "tenant_id": "tenant-alpha",
  "fixture_id": "fixture-alpha"
}
```

Each `before` inventory must list exactly the IDs declared in
`fixture.expected_preinventory` for that plane, and every resource must carry
the fixture's `tenant_id` and `fixture_id`. The matching `after` plane
inventory must be empty. The sentinel inventories must be non-empty and carry
the `sentinel_fixture` tenant and fixture, which must differ from the target
fixture's. The `before` sentinel must list exactly `expected_resource_ids`, and
the sentinel must be identical before and after. Synthetic status comes from the
declared `kind` and `tenant_kind`, never from how an identifier is spelled. Boolean success fields without these concrete inventories do
not constitute evidence.

## What the validator checks

- the expected full target commit matches;
- the run is fresh relative to the configured reference time: `finished_at`
  and both observations fall within `--max-age-seconds`, and so does the run
  duration;
- timestamps are strict RFC 3339 UTC (`YYYY-MM-DDTHH:MM:SS[.ffffff]Z`) and
  order start, before, after, and finish;
- the fixture and sentinel are explicitly synthetic and disjoint;
- observed pre-teardown inventories match the declared expected inventories;
- every required plane was populated before teardown;
- every required plane has a successful, available, permitted after-observation;
- target resources are absent after teardown;
- the unrelated sentinel tenant inventory is unchanged;
- backup erasure and kernel payload sanitisation remain `UNVERIFIED`.

The required machine-verifiable planes are `drain_routes`, `openbao`,
`spire_svid`, `tailscale`, and `namespace`.

## Limits

Validation proves only that one supplied JSON document has the required shape
and is internally consistent. It does not authenticate the collector, bind the
manifest cryptographically, inspect a cluster, prove backup-media erasure,
prove kernel-memory sanitisation, or substitute for live teardown checks.

The report always sets `phase3_certified` and `authenticity_verified` to false.
No valid manifest can label the whole SLED Phase 3 certified. Runtime collectors
must obtain inventories directly from the relevant planes, retain their native
evidence separately, and run against an attributed disposable synthetic fixture.
