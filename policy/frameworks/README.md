# Policy Framework Packs

Regulatory compliance policy packs evaluated offline by the OSRAMP Go compliance
scanner against Kubernetes manifests using `cel-go`.

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
- **Control** is a single auditable requirement with a risk triple.
- **Check** is a concrete CEL expression the scanner evaluates against
  `object` (a deserialised Kubernetes pod template spec).

## Strictness Tiers

Each framework ships at three strictness levels, encoded as semantic versions:

| Version | Tier     | Intent                                                    |
|---------|----------|-----------------------------------------------------------|
| v1.0    | Lax      | Bare minimum critical security. 3-5 checks per set.      |
| v2.0    | Standard | Defence-in-depth. Resource limits, probes. 5-8 per set.  |
| v2.1    | Strict   | Full manifest coverage. Labels, annotations. 8-12 per set.|

Higher tiers are strict supersets of lower tiers -- every check in v1.0
appears in v2.0, and every check in v2.0 appears in v2.1 (plus additional
checks).

## Risk Triples and FAIR Quantification

Each control carries a `riskTriple` with three values:

```yaml
riskTriple:
  min: 5000      # Best-case single loss event (GBP)
  mode: 25000    # Most likely single loss event (GBP)
  max: 120000    # Worst-case single loss event (GBP)
```

These map to FAIR (Factor Analysis of Information Risk) loss magnitude
estimation using a PERT distribution. The scanner aggregates risk triples
across failing controls to produce a monetary exposure estimate for the
entire workload.

Values are denominated in GBP and calibrated for UK regulated industries
(financial services, critical infrastructure, healthcare).

## Adding a New Framework

1. Create `policy/frameworks/<framework-id>/v1.0/framework.yaml`.
2. Follow the schema: `framework` metadata, then `controlSets` containing
   `controls` with `checks`.
3. Every check must have a valid `cel` expression evaluable by `cel-go`
   against a Kubernetes pod template spec accessed as `object`.
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
