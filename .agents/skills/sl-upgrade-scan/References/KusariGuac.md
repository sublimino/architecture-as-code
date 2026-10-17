# Kusari and GUAC integration notes

These notes say what the public Kusari tools and GUAC add to an upgrade scan. The sources are
the public READMEs, read with `gh api repos/<owner>/<repo>/readme` on 2026-10-17. This skill
implements only the SBOM output (`--sbom-out`). The rest is a plan.

## What each tool does

| Tool | Source | What it does | Use for upgrades |
|------|--------|--------------|------------------|
| kusari-cli | [kusaridev/kusari-cli](https://github.com/kusaridev/kusari-cli) (MIT) | The `repo scan` command runs Kusari Inspector. In CI it posts a summary comment and inline comments on the lines with findings. | Checks the change that makes a bump, after this skill chooses the bump. |
| kusari-ingest | [kusaridev/kusari-ingest](https://github.com/kusaridev/kusari-ingest) (Apache-2.0) | A GitHub Action that sends SBOMs, SLSA provenance and other attestations to the Kusari Platform. With `generate: true` it builds a CycloneDX SBOM from a source tree or an image. It needs a tenant and client credentials. | Takes the SBOM that `--sbom-out` writes, through `file-path`. |
| kusari-skills | [kusaridev/kusari-skills](https://github.com/kusaridev/kusari-skills) (Apache-2.0) | A Claude Code plugin with `/kusari-change-evaluate` and `/kusari-change-fix`. It needs kusari-cli v0.21.0 or later, or the `kusari-inspector` MCP server. | Runs after a bump to scan the revision and apply fixes. |
| GUAC | [guacsec/guac](https://github.com/guacsec/guac) (Apache-2.0, release v1.1.0 of 2026-03-13) | A graph of software composition with a GraphQL API. It takes SPDX, CycloneDX, SLSA, in-toto, OSV, OpenVEX, CSAF and Scorecard documents. Its collectors include deps.dev and OSV. | Answers estate-wide questions that one repository scan cannot. |

## What the combination gives

This skill answers the question "what in this repository is behind?". GUAC answers the
question "where in the estate does this version run?". An example is "which workloads run
OpenBao earlier than 2.7". To get that answer:

1. Run `upgrade-scan scan --sbom-out <dir>` in each repository. The tool needs syft (anchore/syft).
   Syft is not installed on this host today, so the option reports that and writes nothing.
2. Ingest the SBOMs. Use `guacone collect files <dir>` for a local GUAC, or kusari-ingest with
   `file-path` for the Kusari Platform.
3. Query by package URL. For OpenBao, use `pkg:oci/openbao` or the Go module
   `github.com/openbao/openbao`. Filter on the version.

Image SBOMs give better data than a source-tree SBOM, because they list the OS packages
that grype finds. Kusari-ingest can generate them with `image:`. Syft can generate them with
`syft scan registry:<ref>`. This skill does not do it yet.

## Not done

- No GUAC or Kusari API calls. Both need a running service or a tenant, and neither exists here.
- No VEX output. OpenVEX statements could record why a CVE that the upgrade does not fix is not
  exploitable. GUAC and kusari-ingest (`open-vex`) both accept VEX.
- No image SBOMs. See the paragraph above.
