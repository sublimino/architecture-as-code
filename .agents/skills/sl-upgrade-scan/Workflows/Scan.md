# Scan workflow

Use this workflow to find the upgrades worth making and to make them safely.

## 1. Inventory

Run the inventory first. It does not use the network.

```bash
.agents/skills/sl-upgrade-scan/Tools/upgrade-scan inventory --md -
```

Check that the families you care about are present. If a pin is missing, the extractor does
not know its format. Add a test in `test/unit/sl-upgrade-scan/inventory.test.ts` before you
extend `Tools/inventory.ts`.

## 2. Resolve and rank

```bash
.agents/skills/sl-upgrade-scan/Tools/upgrade-scan scan --md /tmp/upgrades.md --json /tmp/upgrades.json
```

Read the `Unknown upstream` section. Each line gives a reason. Fix a missing mapping in
`Tools/upstreams.json`. Do not invent a version.

## 3. Add image CVEs for the top images

```bash
.agents/skills/sl-upgrade-scan/Tools/upgrade-scan scan --ecosystem oci-image --image-scanner grype --image-scan-limit 5 --md -
```

## 4. Choose

Take the rows from the top. For a row with a breaking hint, read the upstream release notes
from the source column before you change anything.

## 5. Bump and prove

Change the exact file:line in the row, and every other location the JSON lists. Run the
tests for that component. Run the scan again: the row must be gone or show `none`.
