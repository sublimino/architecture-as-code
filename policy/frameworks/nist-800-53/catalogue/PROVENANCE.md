# Catalogue provenance

`nist-sp-800-53-rev5-ids.tsv` is a mechanical extract of the control
identifiers and titles published by NIST as OSCAL JSON. It is the ground truth
the `nist-800-53` pack's control references are anchored to.

| Field | Value |
|-------|-------|
| Source | `usnistgov/oscal-content`, path `nist.gov/SP800-53/rev5/json/NIST_SP-800-53_rev5_catalog.json`, branch `main` |
| Fetched | 2026-10-10 |
| Catalog UUID | `ea7c7688-79c5-463b-a91b-0650f2d98623` |
| `metadata.version` | `5.2.0` |
| `metadata.last-modified` | `2026-05-11T16:01:09.00000-00:00` |
| OSCAL schema version | `1.2.2` |
| Controls extracted | 1196 (base controls and enhancements) |

The catalog UUID is the stable identity of this release of the catalogue. If a
future NIST release renumbers or withdraws a control, the UUID changes. The
extract is then regenerated with `./extract.sh`, and `anchor-test.sh` reports the
pack references that no longer resolve. That is the intended workflow: the
catalogue moving is a signal, not a nuisance.

## Identifier form

OSCAL keys enhancements in dotted form. `AC-6(1)` — the form NIST prose and
this pack both use — is `AC-6.1` in the extract. `anchor-test.sh` normalises
the parenthesised form before lookup, so the pack may continue to write
`AC-6(1)` and the test still resolves it.

Enhancements are distinct controls with distinct statements. `AC-6(1)`
("Authorize Access to Security Functions") and `AC-6(9)` ("Log Use of
Privileged Functions") are not interchangeable. Neither is a synonym for
their parent `AC-6` ("Least Privilege"). The test treats them as separate keys
for exactly that reason.

## Regenerating

```sh
./extract.sh                      # fetch the published catalogue, then extract
./extract.sh /path/to/catalog.json  # extract from a local copy
```

Requires `jq` and, for the fetching form, `curl`. The extract is sorted with
`LC_ALL=C` so regeneration is byte-stable across machines and locales.
