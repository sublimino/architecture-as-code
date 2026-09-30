# Kusari EAP Forensic Evidence Bundle - Specification (SLDC-P5-2)

The five-step containment run has five steps: Deploy, Auto-Claim, Provoke,
In-Sentinel Detect and Freeze. It must leave evidence that a third-party
auditor can check without ControlPlane's toolchain. This document defines the
eight Appendix F.2 artifacts and how they are bound together. It also defines
how they are packaged and how to verify them by hand.

| Piece | Path |
| :---- | :--- |
| Packager | `scripts/package-eap-evidence.sh` |
| Verifier | `scripts/verify-eap-evidence.sh` |
| Shared contract (both scripts source it) | `scripts/lib/eap-evidence.sh` |
| JSON Schema | `schemas/eap-evidence-bundle-schema.json` |
| jq-only schema validator | `scripts/lib/json-schema-lite.jq` |
| Tamper-detection tests | `test/evidence-bundle-integrity.bats` |
| Test fixture (`evidence_origin: fixture`) | `test/fixtures/eap-evidence/` |

## 1. Provenance chain

```
Ed25519 signature (bundle-header.json.sig)            ← key .keys/witness.pem
  └─ bundle-header.json  (signed_at, git commit, operator, host, per-artifact sha256+bytes)
       └─ sha256 of audit-signature.sha256            ← artifact 8
            └─ sha256 of each of the seven raw artifacts
Outer: kusari-eap-evidence-<UTC>.tar.gz + .tar.gz.sha256
```

Each link is checkable on its own. `sha256sum -c` alone proves the artifacts
match the manifest. The signed header proves the manifest is the one that was
signed, and when and by whom. The public-key fingerprint shows who signed it.
Editing any artifact breaks the manifest. Re-hashing the manifest breaks the
header. Rewriting the header breaks the signature. Re-signing with another key
changes the fingerprint away from the published one. Each of these attacks is
a named test in `test/evidence-bundle-integrity.bats`.

## 2. The eight artifacts

All eight are regular files (symlinks are refused) and must be non-empty. The
tenant is always `kusari` / `4b53ab6b`. The strings `kurasi` and `6f82ad81`
anywhere in the evidence void the bundle (Shared Pattern 1, fail closed).

| # | File | Producer (P5-1 step) | Format and contract |
|---|------|----------------------|---------------------|
| 1 | `preflight-manifest.json` | setup | JSON, `$defs/preflightManifest`. Required: `captured_at`, `tenant {id: kusari, domain_hash: 4b53ab6b}`, `clusters.workload.context` and `clusters.hub.context` (`kind-osramp`, `kind-signalloom-hub`), `git.commit` (40 hex). Optional: `schema: "sldc-eap-preflight/v1"`, `evidence_origin` (`live` or `fixture`), `git.dirty`, `git.diffstat`, `tools` (tool versions). The file name and format are fixed: a key/value `preflight-manifest.json.txt` does not satisfy it. |
| 2 | `step1-flux-reconcile.txt` | Step 1 | Text. Kustomization readiness, `lastAppliedRevision` digest and replica status. Every `restartCount: N` line in it must have N = 0. |
| 3 | `step2-registry-claim.json` | Step 2 | JSON, `$defs/registryClaim`. Required: `tenant_hash: 4b53ab6b`, `model_name`, and `tenant_id` or `tenant` equal to `kusari`. Optional: `agent_name: kusari-agent`, `claimed_at`, `lifecycle_state`, and the raw `query` and `row` of the PostgreSQL lookup. |
| 4 | `step3-provocation-act.log` | Step 3 | Text. Request line and HTTP response of `POST /act/read-passwd` through the API-server service proxy. |
| 5 | `step4-ebpf-observation.json` | Step 4 | JSON, `$defs/ebpfObservation`: one Shared Pattern 2 normalised event, or `{observations: [event, ...]}`. Each event carries `actor_id`, `pod_name`, `syscall` ∈ {`sys_enter_openat`, `tcp_connect`, `sys_enter_execve`}, a target (`filename`, `target` or `remote_endpoint`) and a `cgroup_path` (top level or `labels.cgroup_path`). |
| 6 | `step5-cgroup-freeze.txt` | Step 5 | Text. **Primary forensic proof.** Must contain the kernel `cgroup.events` line `frozen 1` and no `frozen 0` line, and the pod's `restartCount: 0` (Shared Pattern 3). By convention it also carries `cpu.stat`, the Flux `reconcile: disabled` state (Shared Pattern 4) and the two-scrape record `cadvisor_cpu_seconds: A -> B`. If that record is present, A must equal B. |
| 7 | `step5-cadvisor-metrics.prom` | Step 5 | Prometheus text from the kubelet `/metrics/cadvisor` endpoint, with at least one `container_cpu_usage_seconds_total` sample. 0 mCPU is proven by `cadvisor_cpu_seconds: A -> A` in artifact 6, or else by a series here with at least 2 samples that are all equal. |
| 8 | `audit-signature.sha256` | packager | `sha256sum` text output: exactly seven lines `<64 lowercase hex>  <name>`, in the order above. |

The packager also adds three signing files. None of them is an evidence
artifact.

| File | Content |
| :--- | :------ |
| `bundle-header.json` | Root schema object. It records `schema: sldc-eap-evidence-bundle/v1`, `bundle_name`, `signed_at`, `source_date_epoch`, `evidence_origin`, `git {commit, branch, dirty}` of the packaging checkout, `operator {identity, source}`, `host {os, kernel_release, architecture, container_runtime}`, `artifacts[7] {name, sha256, bytes}`, `manifest {name, sha256}` and `signature {algorithm: ed25519, file, public_key_sha256}`. |
| `bundle-header.json.sig` | 64-byte raw Ed25519 signature over the exact bytes of `bundle-header.json`. |
| `signing-key.pub.pem` | The signer's public key (SubjectPublicKeyInfo PEM). Useful for convenience only; trust comes from the published fingerprint. |

### Evidence origin

`evidence_origin` separates evidence taken from a real run (`live`) from
synthetic test input (`fixture`). A preflight manifest without the field is
recorded as `unknown`. The packager signs all three and prints a
warning for anything but `live`. The verifier does the same, and fails
anything but `live` under `--require-live`. **A certification bundle must pass `--require-live`.** The
committed fixture under `test/fixtures/eap-evidence/` is `fixture` on purpose.

## 3. Packaging

```bash
scripts/package-eap-evidence.sh                      # latest run under ~/kusari-e2e/
scripts/package-eap-evidence.sh ~/kusari-e2e/20261002T091500 --out /secure/export
SOURCE_DATE_EPOCH=1790726400 scripts/package-eap-evidence.sh DIR   # byte-reproducible
```

The packager runs these steps in order and stops at the first failure (exit 1,
reason on stderr). **Nothing is written before step 3.**

1. **Key gate (hard blocker).** It resolves `$EAP_SIGNING_KEY`, or else
   `<keys dir>/witness.pem`. The keys directory comes from
   `scripts/lib/keys.sh`, which is shared across worktrees. The key must
   exist, be readable, parse without a passphrase, and be Ed25519. If not,
   packaging stops. Signing never prompts.
2. **Contract gate.** It runs the section 2 content checks on the seven raw
   artifacts. The checks are: presence, non-empty, regular file, JSON syntax,
   schema, `frozen 1`, `restartCount 0`, 0 mCPU flatline and tenant sweep.
   `frozen 0` is reported as `PRIMARY FORENSIC PROOF INVALID`.
3. **No re-blessing.** If an `audit-signature.sha256` already exists and
   `sha256sum -c` fails against it, packaging stops. The evidence changed
   after it was signed.
4. **Manifest.** `sha256sum <the seven files, in order> > audit-signature.sha256`,
   then a format check.
5. **Header and signature.** It writes `bundle-header.json`, checks it
   against the root schema, and signs it with
   `openssl pkeyutl -sign -rawin`.
6. **Tarball.** It builds `kusari-eap-evidence-<YYYYmmddTHHMMSSZ>.tar.gz` in
   `$EAP_OUT_DIR`, or else `ci-evidence/`. The archive holds one directory of
   eleven files. It is built with `tar --sort=name --mtime=@<epoch> --owner=0
   --group=0 --numeric-owner`, with files at 0644 and the directory at 0755,
   and compressed with `gzip -n -9`. The `<tarball>.sha256` checksum sits
   beside it.
7. **Self-verification.** It runs `verify-eap-evidence.sh` on the tarball. If
   that fails, the tarball is deleted.

`signed_at`, the tarball name and every tar mtime come from
`SOURCE_DATE_EPOCH`, or from the current time when it is unset. Ed25519
signatures are deterministic. Two runs over the same evidence with the same
epoch, checkout and host therefore produce identical tarball digests. A test
in the suite proves this.

Injectable boundaries: `EAP_EVIDENCE_ROOT`, `EAP_OUT_DIR`, `EAP_SIGNING_KEY`,
`EAP_REPO`, `EAP_OPERATOR`, `EAP_CONTAINER_RUNTIME` and `SOURCE_DATE_EPOCH`.

## 4. Verification

```bash
scripts/verify-eap-evidence.sh kusari-eap-evidence-20261002T091500Z.tar.gz --require-live
scripts/verify-eap-evidence.sh ~/kusari-e2e/20261002T091500 --pubkey witness-pub.pem
```

Every check prints `OK`, `WARN` or `FAIL`. The run ends with `VERDICT:
PASS|FAIL`, and the exit code is 0, 1, or 2 for a usage error.

| Group | Checks |
| :---- | :----- |
| Archive (tarball only) | The outer `.sha256` matches. There is one top-level `kusari-eap-evidence-<UTC>` directory. No entry has an absolute or `..` path. Only regular files are present: no symlinks, hard links or devices. Files are `-rw-r--r--` and the directory is `drwxr-xr-x`. No entry falls outside the eleven bundle files. The archive is extracted with `--no-same-owner --no-same-permissions`, and only after the listing passes. |
| Content | Everything in packaging step 2. |
| Manifest | Exactly seven lines, in order, each with a 64-hex digest, and `sha256sum --check --strict` reports zero mismatches. |
| Header | Conforms to the root schema. Its manifest digest and every artifact digest and byte count match the files. |
| Signature | The trusted public key is `--pubkey`, else `$EAP_VERIFY_PUBKEY`, else `<keys dir>/witness-pub.pem`. Its fingerprint must equal `signature.public_key_sha256` and the fingerprint of the bundled `signing-key.pub.pem`, and the Ed25519 signature must verify. With no trusted key at all, the bundled key is used and a WARN prints its fingerprint for manual comparison. |
| Origin | The header and `preflight-manifest.json` agree. `fixture` gives a WARN, or a FAIL under `--require-live`. |

### By hand, with standard tools only

```bash
sha256sum -c kusari-eap-evidence-*.tar.gz.sha256
tar -tvzf kusari-eap-evidence-*.tar.gz          # 1 dir 0755 + 11 files 0644, owner 0/0
tar -xzf kusari-eap-evidence-*.tar.gz && cd kusari-eap-evidence-*/
sha256sum -c audit-signature.sha256             # 7 × OK
sha256sum audit-signature.sha256                # == jq -r .manifest.sha256 bundle-header.json
openssl pkey -pubin -in witness-pub.pem -outform DER | sha256sum   # == .signature.public_key_sha256
openssl pkeyutl -verify -pubin -inkey witness-pub.pem -rawin \
  -in bundle-header.json -sigfile bundle-header.json.sig            # Signature Verified Successfully
grep -x 'frozen 1' step5-cgroup-freeze.txt && ! grep -x 'frozen 0' step5-cgroup-freeze.txt
jq -n --slurpfile schema eap-evidence-bundle-schema.json --slurpfile doc step4-ebpf-observation.json \
  --arg ptr '#/$defs/ebpfObservation' -f json-schema-lite.jq      # no output = conforms
```

## 5. Schema dialect

`schemas/eap-evidence-bundle-schema.json` declares draft 2020-12. It uses only
the keywords that `scripts/lib/json-schema-lite.jq` implements:

| Keyword group | Keywords |
| :------------ | :------- |
| References and composition | `$ref` (local pointers only), `anyOf` |
| Scalars | `type`, `const`, `enum`, `pattern`, `minLength`, `minimum`, `maximum` |
| Objects | `required`, `properties`, `additionalProperties: false` |
| Arrays | `items`, `minItems`, `maxItems` |

That keeps verification to jq alone, with no Python `jsonschema` and no Node
`ajv`. It also means a standard validator
gives the same verdict. Add a keyword to the schema only after the validator
supports it. The validator silently ignores keywords it does not know.

`x-rawArtifacts` lists the seven raw artifacts. `x-artifactSchemas` maps each
JSON artifact to its `$defs` entry.

## 6. Known limits

- The bundle proves integrity and signer identity, not truth. A signer who
  holds the key can sign fabricated evidence. `evidence_origin` is
  self-declared by the producer of `preflight-manifest.json`. Non-repudiation
  therefore rests on custody of `.keys/witness.pem` and on P5-1 capturing
  artifacts directly from the clusters.
- `signed_at` is the packager host's clock (or `SOURCE_DATE_EPOCH`). No
  trusted timestamp authority is involved.
- `host.*` describes the packaging host, which is not necessarily the
  cluster's node. The cluster's own versions belong in
  `preflight-manifest.json`.
- Volatile state must be captured while the container is frozen (see the
  errata before P5-2). The packager only reads files that already exist. It never
  touches the cluster, so it cannot thaw or disturb a frozen pod.
