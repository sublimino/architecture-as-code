# Policy Framework Packs

Regulatory compliance policy packs. The policy engine evaluates them offline
against Kubernetes manifests with `cel-go`.

## Gemara Tension Hierarchy

Each framework follows a four-level hierarchy inspired by Talmudic layered
commentary -- each layer adds specificity and evaluable detail:

```
framework          # The regulatory standard (EU AI Act, NIST 800-53)
  controlSet       # A grouping of related controls (e.g. Art. 9, AC family)
    control        # A specific requirement within the set
      check        # A CEL expression evaluated against a pod spec
```

- **Framework** identifies the regulation, version, and strictness tier.
- **Control Set** maps to a regulatory article or control family.
- **Control** is a single auditable requirement. In `framework.json` a
  control holds `id`, `name`, and `checks`.
- **Check** is a concrete CEL expression the policy engine evaluates against
  `object` (a deserialised Kubernetes pod template spec). In `framework.json`
  each check carries `celExpression`, `riskTriple`, `freqTriple`, and
  `policyVersions`.

## Strictness Tiers

Each framework directory has three version directories, one per strictness
tier. Only the v2.1 `framework.json` of each framework loads. The v1.0 and
v2.0 YAML packs do not load (see
[Adding a New Framework](#adding-a-new-framework)).

| Version | Tier     | Intent                                       | Loads |
|---------|----------|----------------------------------------------|-------|
| v1.0    | Lax      | Bare minimum critical security.              | No    |
| v2.0    | Standard | Defence-in-depth. Resource limits, probes.   | No    |
| v2.1    | Strict   | Full manifest coverage. Labels, annotations. | Yes, from `framework.json` |

In the YAML files, each tier adds controls to the tier below it. The
`framework.json` that loads is a smaller pack than the YAML file beside it.
Count the controls in the packs themselves. A count written here goes stale.

## Risk Triples and FAIR Quantification

In `framework.json`, each check carries a `riskTriple` with three values. In
the YAML files, the triple sits on each control.

```yaml
riskTriple:
  min: 5000      # Best-case single loss event
  mode: 25000    # Most likely single loss event
  max: 120000    # Worst-case single loss event
```

These map to FAIR (Factor Analysis of Information Risk) loss magnitude
estimation using a PERT distribution. The policy engine aggregates risk
triples across failing checks to produce a monetary exposure estimate for the
entire workload.

The packs carry no currency field.

## Adding a New Framework

The policy engine reads these packs. Its loader,
[`loader.go`](../../d2-signalloom/apps/policy-engine/frameworks/loader.go), reads
`framework.json` first. It reads `framework.yaml` only when no `framework.json`
exists. It parses either file as JSON.

CAUTION: Do not edit only `framework.yaml` in a version directory that also
has a `framework.json`. The policy engine ignores the YAML file there, so your
change has no effect on scan results.

The v2.1 directories contain both files. Each `framework.json` is a separate,
smaller pack with a different top-level shape. No script makes it from the
YAML file, so the two files can differ. The YAML files are not valid JSON. The
policy engine logs a load error for a version directory that has only
`framework.yaml`, and it skips that version.

WARNING: A pack that is only in YAML syntax does not load. The policy engine
skips it, and the scan results do not include it. Write each new pack as
`framework.json`, in the shape of the existing v2.1 `framework.json` files.

1. Create `policy/frameworks/<framework-id>/v1.0/framework.json`.
2. Follow the shape of an existing v2.1 `framework.json`: `id`, `name`,
   `version`, then `controlSets` containing `controls` with `checks`.
3. Every check needs a `celExpression` that `cel-go` can evaluate against
   a Kubernetes pod template spec accessed as `object`.
4. Add v2.0 (standard) and v2.1 (strict) tiers with progressively more
   checks and higher risk triples.
5. Update this README if the framework introduces novel conventions.

## CEL Expression Conventions

Expressions receive the pod template spec as `object`. Common patterns:

```cel
# All containers run as non-root
object.spec.containers.all(c, c.securityContext.runAsNonRoot == true)

# No privileged containers
object.spec.containers.all(c, !c.securityContext.privileged)

# Drop all capabilities
object.spec.containers.all(c, c.securityContext.capabilities.drop.exists(d, d == "ALL"))

# Label exists
has(object.metadata.labels.app)

# Annotation contains value
object.metadata.annotations.exists(k, k == "osramp.io/sbom-url")

# Image pinned by digest
object.spec.containers.all(c, c.image.contains("@sha256:"))

# Resource limits set
object.spec.containers.all(c, has(c.resources) && has(c.resources.limits))
```
