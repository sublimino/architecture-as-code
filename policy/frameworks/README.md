# Policy Framework Packs

Regulatory compliance policy packs. The policy engine evaluates them offline
with `cel-go` against a Kubernetes pod template (`object`), an agent context
document (`agent`) and a runtime request context (`request`). The binding
contract and the fixture rules are in [CONFORMANCE.md](CONFORMANCE.md).

## Gemara Tension Hierarchy

Each framework follows a four-level hierarchy inspired by Talmudic layered
commentary -- each layer adds specificity and evaluable detail:

```
framework          # The regulatory standard (EU AI Act, NIST 800-53)
  controlSet       # A grouping of related controls (e.g. Art. 9, AC family)
    control        # A specific requirement within the set
      check        # A CEL expression the policy engine evaluates
```

- **Framework** identifies the regulation, version, and strictness tier.
- **Control Set** maps to a regulatory article or control family.
- **Control** is a single auditable requirement. It holds `id`, `name`,
  `description` and `checks`.
- **Check** is a concrete CEL expression. Each check carries `id`, `name`,
  `celExpression`, `riskTriple`, and optionally `freqTriple`,
  `policyVersions`, `severity`, `remediation`, `description` and `status`.

## Strictness Tiers

`eu-ai-act` and `nist-800-53` each have three version directories, one per
strictness tier. Every version directory with a `framework.json` loads.

| Version | Tier     | Intent                                       |
|---------|----------|----------------------------------------------|
| v1.0    | Lax      | Bare minimum critical security.              |
| v2.0    | Standard | Defence-in-depth. Resource limits, probes.   |
| v2.1    | Strict   | Workload checks plus agent and request governance. |

Count the checks in the packs themselves. A count written here goes stale.

The v1.0 and v2.0 packs were converted from a legacy YAML dialect. They carry
no `freqTriple`, so the engine computes zero annual loss for their failures.

## Risk Triples and FAIR Quantification

Each check carries a `riskTriple` with three values:

```json
"riskTriple": { "min": 5000, "mode": 25000, "max": 120000 }
```

These map to FAIR (Factor Analysis of Information Risk) loss magnitude
estimation using a PERT distribution. `freqTriple` has the same shape and
gives the loss event frequency per year. A check with no `freqTriple` has
zero frequency, so its failures carry zero annual loss. The policy engine
aggregates the results across failing checks into a monetary exposure
estimate for the workload. Read
[The calibration statement](#the-calibration-statement) before you quote any
figure the engine produces.

The packs carry no currency field.

## What a pack triple is a share of

Read this before comparing any pack figure against any published loss figure.

A pack `riskTriple` mode is **not** the cost of a loss event. It is the
**attributable share of one loss event assigned to one failed control**. The
pack modes run from about £5,000 to about £120,000. Published single-event loss
medians sit one to two orders of magnitude above that range. Cyentia IRIS 2022
puts the typical single event near $266,000 and the top five per cent above
$52,000,000 (<https://www.cyentia.com/iris-2022/>). IRIS 2025 reports the
median moving from about $190,000 to about $3,000,000 over fifteen years
(<https://www.cyentia.com/iris-2025/>).

The event-level figures in this estate are the `SCN-*` magnitudes in
[`risk/org/acme.yaml`](../../risk/org/acme.yaml), which run from £60,000 to
£4,000,000. Those are loss events. A pack triple is a slice of one of them.

Nothing in this repository said so before 2026-10-11. A reviewer who compares a
pack mode against an IRIS median therefore reads a hundred-fold error where
there is an attribution model. Both figures are defensible. They answer
different questions.

Each priced check now carries a derivation entry in its pack's
`CALIBRATION.md`, keyed by check id. The entry names the `SCN-*` scenario the
check is a share of and the anchor classes behind its two triples. It also
carries the `P_org`/`S_path`/`C_check` reasoning and a confidence letter. The registry of
anchor classes is [ANCHORS.md](ANCHORS.md). The statutory ceilings, which are a
`max` and never a `mode`, are in [PENALTIES.md](PENALTIES.md).

The derivation lives beside the pack rather than inside `framework.json`. The
loader runs `DisallowUnknownFields`, so a per-triple provenance field is a
loader change rather than a data change. That change is still open. It is
section 7 of [the open decisions](../../docs/fair-methodology-open-decisions.md).

## The calibration statement

This is the one statement about the money. Quote it. Do not paraphrase it, and
do not write a shorter version for a single page.

> These figures are a FAIR-method simulation of declared expert estimates, not
> measurements. The inputs are calibrated judgements against named loss classes.
> No public dataset prices these controls. Re-estimate every figure against your
> own incident history. Have your risk function sign it off before any board,
> regulatory, or financial use.

Every other document in this repository links to this section rather than
restating it. Three places must carry it. The pack pages under
`policy/frameworks/`, the money section of
[`CONFORMANCE.md`](CONFORMANCE.md#pinning-money), and any report or dashboard
that shows a figure.

### Why each clause is in it

| Clause | The fact behind it |
| :--- | :--- |
| a FAIR-method simulation | The engine draws from beta-PERT distributions over the two triples. The method is FAIR. The numbers are not FAIR data. |
| declared expert estimates | Of 134 shipped checks, 132 carry a loss magnitude and 53 carry a frequency. Those are 65 distinct magnitude triples and 25 distinct frequency triples, almost all of them round numbers. The check shape still has no field for provenance, author, date, or anchor class, so the derivation sits in a per-pack `CALIBRATION.md` keyed by check id rather than on the triple. |
| not measurements | Nothing in this repository tests that any figure is the right figure. Calibration is an input, not a computable property. |
| no public dataset prices these controls | No public or commercial loss dataset prices "a service-account token was auto-mounted" or "no model card was published". The mapping is expert judgement and cannot be reduced further. |
| re-estimate against your own incident history | [`risk/org/acme.yaml`](../../risk/org/acme.yaml) is the standard to copy. It names anchor classes, states that each triple is an estimate rather than a measurement, and requires risk sign-off. |

### What the figure does not depend on

| It does not depend on | Why |
| :--- | :--- |
| the verdict | `fair.Simulate` runs before and regardless of `status`, so a `pass` and a `fail` on one check carry the same four figures. |
| the workload | Nothing about the scanned agent, its data access, or its blast radius reaches the simulation. |
| anything but the check name and the triples | The seed is an FNV-1a hash of the check ID, so a rename moves every figure on that row. `TestConformance_MoneySeedDerivedFromCheckID` pins both halves of that. |

The `calibrationSource` field on every scan row reads
`declared-estimate-unanchored`. The field is set in Go, by the engine, and not
by the author of a triple. It reads the same on a priced row and on a row that
prices at zero. Per-triple provenance is an open decision. See
[FAIR methodology: the open decisions](../../docs/fair-methodology-open-decisions.md).

## Pricing coverage across the estate

The table below is produced from every `framework.json` in this tree.
`make policy-pricing-counts` fails if it drifts from the packs. Each pack page
carries the same table for its own versions.

<!-- pricing-counts:begin -->
| Pack and version | Checks | Priced | Unpriced | Placeholder |
| :--- | ---: | ---: | ---: | ---: |
| `cis-kubernetes@v1.8.0` | 17 | 17 | 0 | 0 |
| `cra@v1.0.0` | 3 | 3 | 0 | 0 |
| `dora@v1.0.0` | 1 | 0 | 1 | 1 |
| `eu-ai-act@v1.0.0` | 7 | 0 | 7 | 0 |
| `eu-ai-act@v2.0.0` | 19 | 0 | 19 | 1 |
| `eu-ai-act@v2.1.0` | 11 | 6 | 5 | 0 |
| `finos-aigf@v1.0.0` | 16 | 13 | 3 | 0 |
| `nis2@v1.0.0` | 1 | 0 | 1 | 1 |
| `nist-800-53@v1.0.0` | 14 | 0 | 14 | 0 |
| `nist-800-53@v2.0.0` | 28 | 0 | 28 | 0 |
| `nist-800-53@v2.1.0` | 17 | 14 | 3 | 0 |
| **Estate total** | **134** | **53** | **81** | **3** |

An unpriced check contributes GBP 0.00 to every total however often it
fails. Of 134 check(s) on this page, 53 are priced and 81 are not.
Written by `policy/frameworks/pricing-counts-test.sh`. Do not edit by hand.
<!-- pricing-counts:end -->

## How the Loader Reads a Pack

The loader is
[`loader.go`](../../d2-signalloom/apps/policy-engine/frameworks/loader.go).

- It reads `framework.json` when one exists. It reads `framework.yaml` only
  when there is no `framework.json`.
- `framework.json` must be JSON. `framework.yaml` must be YAML in the same
  canonical shape. Neither may contain a key the shape does not define, so a
  misspelt key is a load error, not a silently empty field.
- Every check must have an `id` and a non-empty `celExpression`.
- A pack that breaks any of these rules does not load. The engine logs the
  error and skips the pack. `TestLoad_EveryShippedPackLoadsCompletely` fails
  for any shipped pack that does not load.

Every shipped pack is a single `framework.json`, and no pack carries a
`framework.yaml`. The YAML fallback exists only for a pack with no JSON file.

## Adding a New Framework

1. Create `policy/frameworks/<framework-id>/v1.0/framework.json` in the shape
   of an existing `framework.json`: `id`, `name`, `version`, then
   `controlSets` containing `controls` with `checks`.
2. Give every check a `celExpression`, a `riskTriple` **and a `freqTriple`**.
   A check with no frequency triple, or an all-zero one, prices at £0.00 however
   often it fails, because `fair.Simulate` multiplies magnitude by frequency.
   This step used to say "a `celExpression` and a `riskTriple`". That omission
   is how 64 of 127 checks came to report zero exposure silently, because four
   pack versions were authored as instructed. If the frequency genuinely is
   not calibrated yet, **declare the check unpriced** rather than leaving the
   zero implicit. See `nist-800-53/catalogue/{unpriced.tsv,pricing-test.sh}`
   for the pattern. It fails a check that is neither priced nor declared. It
   also fails a declaration for a calibrated or non-existent check. Never invent
   a triple to make a number appear.
3. **Cite the primary source.** Give every control the article, annex point or
   recommendation number it implements, verbatim from the publisher, and record
   the URL you read. Four EU AI Act paragraph citations were wrong and three
   packs carried none at all. A mis-cited article is the defect a customer
   repeats to a regulator. Anchor it mechanically where the publisher offers
   machine-readable text (`nist-800-53/catalogue/` against the NIST OSCAL
   catalogue, `cra/catalogue/` against the Publications Office Cellar XHTML).
4. **Guard container types.** Write `type(x) == map` before reaching into any
   `agent`/`request` object. Without it a container arriving as a JSON **list**
   makes the check `error` rather than `fail`. An errored check is neither
   passed nor failed and carries no exposure, so a critical control vanishes
   instead of failing. Note the trap: string, number and null all fail
   correctly, so only the list form exposes it. This bit the FINOS AIGF and CRA
   packs.
5. **Say what a check cannot see.** If the obligation is a process a scan cannot
   observe, state in the check `description` that it is a proxy. Do not let a
   check ID promise more than the expression tests. For example,
   `immutable-audit-sink` reads a logging-enabled boolean, so a passing report
   line looks like an untested immutability guarantee.
6. If a check reads `agent` or `request`, list each path it reads in
   `<version>/AGENT-CONTEXT.md`. Shipped paths are frozen: extend, never
   rename.
7. Add fixtures under `<version>/fixtures/{unit,integration}/` as
   [CONFORMANCE.md](CONFORMANCE.md) describes: every non-placeholder check
   needs at least one passing and one failing fixture.
8. Run `cd d2-signalloom/apps/policy-engine && go test ./... -count=1`.

## CEL Expression Conventions

A check must fail, not error, on any ordinary valid input. Guard every
optional field with `has()`. `has(a.b.c)` tests only the last field, so guard
each level that can be absent. Decide the meaning of an absent field from the
Kubernetes default.

A per-container security control covers `containers`, `initContainers` and
`ephemeralContainers`. This applies to privileged, privilege escalation,
capabilities, read-only root filesystem, run-as-non-root, image digest, trusted
registry, and seccomp. Note that `kubectl debug --profile=sysadmin` adds a
privileged ephemeral container to a running pod. Resource limits/requests cover
`containers` and `initContainers` only, and probes `containers` only, because
the API forbids resources and probes on ephemeral containers.

```cel
# Per-container control, covering init and ephemeral containers. A pod with no containers fails.
has(object.spec) && has(object.spec.containers) && size(object.spec.containers) > 0 &&
  (object.spec.containers + (has(object.spec.initContainers) ? object.spec.initContainers : []) +
     (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : []))
    .all(c, has(c.securityContext) && has(c.securityContext.allowPrivilegeEscalation) &&
            c.securityContext.allowPrivilegeEscalation == false)

# Absent automountServiceAccountToken means the Kubernetes default (true), so the check fails
has(object.spec) && has(object.spec.automountServiceAccountToken) &&
  object.spec.automountServiceAccountToken == false

# Absent hostNetwork means false, so the check passes
has(object.spec) && !(has(object.spec.hostNetwork) && object.spec.hostNetwork == true)

# Label exists with a non-empty value
has(object.metadata) && has(object.metadata.labels) && has(object.metadata.labels.app) &&
  object.metadata.labels.app != ''

# Annotation exists with a non-empty value
has(object.metadata) && has(object.metadata.annotations) &&
  'osramp.io/sbom-url' in object.metadata.annotations &&
  object.metadata.annotations['osramp.io/sbom-url'] != ''

# Agent governance flag
has(agent.audit_config) && has(agent.audit_config.event_logging_enabled) &&
  agent.audit_config.event_logging_enabled == true
```
