# Restricted security audit workflow

## Preconditions

1. Use an existing repository checkout and installed tools only.
2. Supply a reviewed local Semgrep rules file through `--rules`.
3. Supply `--evidence-dir` only for an existing EAP evidence directory.
4. Supply `--public-key` only as an explicit trusted-operator input. Its location
   outside the bundle is necessary separation, not proof that the key was approved.
5. Do not place private keys or credentials in either argument.

## Run

```bash
.agents/skills/sl-security-audit/Tools/security-audit.sh \
  --repo-root "$PWD" \
  --timeout 120 \
  --rules /trusted/local/semgrep-rules.yml \
  --evidence-dir /path/to/eap-evidence \
  --public-key /trusted/path/witness-pub.pem
```

The collector uses network and process namespaces for secret scans, SAST, and evidence verification.
If a namespace cannot be created, those controls are `BLOCKED`.
The collector never falls back to connected execution.

`SL_SECURITY_AUDIT_SEMGREP_CONFIG` remains a test/local compatibility seam, but
`--rules` is the supported manual configuration surface and takes precedence.
Scanner stdout and stderr are drained into bounded private captures. Committed-tree
archive sizing, streaming extraction, and deadlines prevent unbounded disk growth.

## Interpretation

- `PASS` means only the named control ran and met its narrow contract.
- `FAIL` means deterministic findings or failed cryptographic verification.
- `BLOCKED` means a required prerequisite, permission, tool, or deadline failed.
- `UNVERIFIED` means coverage, trust, freshness, or live observation is absent.
- Collector exit zero means the JSON report is well formed, not that controls passed.

`evidence_origin` is bundle-declared provenance. The `observed_live` metric remains
zero because this offline workflow performs no independent live observation.
OCI verification and live authorization/containment remain explicit `UNVERIFIED` controls.
Those checks require a separately approved execution tier.

## Prohibitions

- No external network, registry rules, OCI registry access, or live cluster tests.
- No installs, baseline regeneration, evidence signing, private-key reads, or fixes.
- Never use a private key for `--public-key`. The collector reads no default signing keys.
- No prompt-injection testing, container escapes, or dynamic adversarial probes.
- Never paste raw logs, finding text, tokens, or scanner stdout into a model.
