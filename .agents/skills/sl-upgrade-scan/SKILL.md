---
name: sl-upgrade-scan
description: "Ranked upgrade report for the #partner-signal-loom repository. Inventories pinned images, Go modules and runtime, Python and npm packages, GitHub Actions and CLI tool pins with file:line. Resolves the latest published version from GitHub releases, OCI registry tags, the Go proxy, PyPI, npm and endoflife.date. Ranks upgrades by the CVEs they fix (OSV, optional grype or trivy), then EOL, then distance. USE WHEN upgrade scan, outdated dependencies, latest versions, CVE upgrade, EOL, end of life, dependency audit, or sl-upgrade-scan."
---

# sl-upgrade-scan

Upgrade triage for the **Signal Loom** (`#partner-signal-loom`) repository. The tool finds
each pin, reads what upstream has published, and ranks the upgrades. You choose and make
the bumps. The tool never edits a file.

## Ideal state

The work is done when all of these hold:

1. **Every pin is in the inventory with its file:line.** Images come from manifests, Kustomize
   `images:`, Helm values, Dockerfiles and Flux `OCIRepository` tags. Go pins come from
   `go.mod` requires and `go`/`toolchain` lines. Packages come from `requirements*.txt` and
   from `package.json` resolved through the lockfile. Actions come from `uses:`, and tools from
   `*_VERSION` pins in Makefiles and scripts.
2. **Every "latest" names its source.** Each recommended version has the URL it was read from
   and the time of the fetch. If nothing can be resolved, the item is `unknown` with a reason.
3. **Upgrades are ranked by risk removed.** First is the highest severity of a CVE that the
   upgrade fixes. Then come end-of-life, distance (major > minor > patch) and the count of
   fixed CVEs.
4. **Major bumps carry a breaking hint**, and so do 0.x minor bumps.

## Tool

[`Tools/upgrade-scan`](Tools/upgrade-scan) is a bash entry point that runs
[`Tools/upgrade-scan.ts`](Tools/upgrade-scan.ts) under bun. Exit codes: `0` report written,
`1` the `--fail-on` threshold is met, `2` usage, `3` environment error.

```bash
T=.agents/skills/sl-upgrade-scan/Tools/upgrade-scan
$T inventory --json -                              # offline: every pin with file:line
$T scan --md /tmp/upgrades.md --json /tmp/upgrades.json
$T scan --only openbao --md -                      # one family
$T scan --ecosystem oci-image --image-scanner grype --image-scan-limit 5 --md -
$T scan --fail-on high --json /dev/null            # CI gate: exit 1 if an upgrade fixes a HIGH
$T scan --sbom-out /tmp/sbom                       # SPDX + CycloneDX through syft, if installed
```

Upstream mapping lives in [`Tools/upstreams.json`](Tools/upstreams.json). Add an image or a
tool there when the report lists it as `unknown`. Injectable for tests:
`UPGRADE_SCAN_HTTP_FIXTURES`, `UPGRADE_SCAN_NOW`, `GRYPE`, `TRIVY`, `SYFT`,
`UPGRADE_SCAN_NO_GH_CLI`. Tests: `make upgrade-scan-test`.

## Workflow

[`Workflows/Scan.md`](Workflows/Scan.md): inventory, then resolve, then rank, then choose, then
bump and prove. Use [`References/KusariGuac.md`](References/KusariGuac.md) to put the result into
GUAC or Kusari.

## Example run

Real run on 2026-10-17. The OpenBao row of the top table (the URL columns are shortened here):

```text
| oci-image quay.io/openbao/openbao | 2.1.1 | 2.7.1 | minor | | | d2-signalloom/apps/fe-signalloom/base/bao-spire-proof.yaml:40 (+6 more) | https://quay.io/v2/openbao/openbao/tags/list?n=1000 (...); release v2.7.1 https://github.com/openbao/openbao/releases/tag/v2.7.1 published 2026-10-01 |
```

## Gotchas

- **GitHub rate limits.** Anonymous calls get 60 an hour. The tool uses `GITHUB_TOKEN`, then
  `GH_TOKEN`, then `gh auth token`. When the limit runs out, it stops calling GitHub and marks
  the remaining items `rate-limited`. It does not guess. Results are cached for 6 hours
  (`--ttl`), so a second run is cheap.
- **Image tag and GitHub release differ.** The recommended image version is the newest registry
  tag with the same shape as the current tag. The shape is the variant suffix (`-alpine`) and
  the precision (`1.27` stays two parts). The GitHub release is shown next to it. A release
  can exist before its image is published. So the tool recommends a registry tag, and falls
  back to the release only when there is no registry data.
- **Image to repository mapping is explicit.** Registries do not link an image to its source
  repository. An image not in `upstreams.json` still gets registry tags but no release link.
  A private image or an image that does not exist is `unknown` with the HTTP status.
- **Pre-releases are skipped by default.** This covers `-rc.1`, `-beta2`, Go
  pseudo-versions and GitHub releases flagged as pre-release. Use `--include-prereleases`.
  Arch tags such as `2.7.1-amd64` have a different suffix and are never chosen.
- **Semver, date and floating tags do not mix.** `2026.10.01` and `20261001` are date tags and
  are compared only to dates. `latest`, `nonroot`, `trixie` and hash tags are reported as
  floating and get no upgrade. A floating pin changes without a commit, which is the finding.
- **First-party images are skipped.** `name:local`, `name:dev`, the org registry, and
  `docker.io/library/<x>` where `<x>` is a directory with a Dockerfile are local builds.
  Rebuild them. Do not bump them.
- **Go vulndb entries usually have no severity.** OSV gives Go standard library and module
  advisories without a CVSS score, so they show as `UNKNOWN`. The ranking puts `UNKNOWN`
  under `MEDIUM` and above `LOW`. Look at the advisory before you skip it.
- **Image CVEs need a pull.** `--image-scanner grype` scans the current image and the
  recommended image. It reports the CVEs present in the first and missing from the second.
  It is off by default because each scan pulls the image.
- **`docs/`, `test/fixtures/`, `MEMORY/` and `Plans/` are not scanned.** Pins there are evidence
  or fixtures. They are not deployed.

## Hand-off

The report gives you the candidates. Bump one family at a time, run the tests that cover it,
and redeploy with **`sl-local-deploy`**. Use **`sl-security-audit`** to scan for secrets and
run SAST.
