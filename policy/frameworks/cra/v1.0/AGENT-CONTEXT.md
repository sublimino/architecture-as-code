# cra v1.0 — agent context

Every check in this pack reads `agent` only. Shipped paths are frozen: extend,
never rename. Every path is `has()`-guarded. An absent path fails the check
instead of erroring.

| Path | Type | Check |
|------|------|-------|
| `agent.security_profile.secure_by_default` | bool | `default-secure-configuration` |
| `agent.sbom.format` | string | `sbom-verified-provenance`: `CycloneDX` or `SPDX` |
| `agent.sbom.verified` | bool | `sbom-verified-provenance` |
| `agent.provenance.slsa_level` | string | `signed-cryptographic-updates`: must equal `SLSA_LEVEL_3` |
