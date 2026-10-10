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
estimate for the workload.

The packs carry no currency field.

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

CAUTION: `eu-ai-act/v2.1`, `nist-800-53/v2.1`, `cra/v1.0`, `dora/v1.0`,
`nis2/v1.0` and `finos-aigf/v1.0` still have a `framework.yaml` beside the
`framework.json`. The loader never reads those YAML files. They are in an
older dialect and differ from the JSON. Do not edit them.

## Adding a New Framework

1. Create `policy/frameworks/<framework-id>/v1.0/framework.json` in the shape
   of an existing `framework.json`: `id`, `name`, `version`, then
   `controlSets` containing `controls` with `checks`.
2. Give every check a `celExpression` and a `riskTriple`.
3. If a check reads `agent` or `request`, list each path it reads in
   `<version>/AGENT-CONTEXT.md`. Shipped paths are frozen: extend, never
   rename.
4. Add fixtures under `<version>/fixtures/{unit,integration}/` as
   [CONFORMANCE.md](CONFORMANCE.md) describes: every non-placeholder check
   needs at least one passing and one failing fixture.
5. Run `cd d2-signalloom/apps/policy-engine && go test ./... -count=1`.

## CEL Expression Conventions

A check must fail, not error, on any ordinary valid input. Guard every
optional field with `has()`. `has(a.b.c)` tests only the last field, so guard
each level that can be absent. Decide the meaning of an absent field from the
Kubernetes default.

A per-container security control (privileged, privilege escalation,
capabilities, read-only root filesystem, run-as-non-root, image digest,
trusted registry, seccomp) covers `containers`, `initContainers` and
`ephemeralContainers`: `kubectl debug --profile=sysadmin` adds a privileged
ephemeral container to a running pod. Resource limits/requests cover
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

# Label exists
has(object.metadata) && has(object.metadata.labels) && has(object.metadata.labels.app)

# Annotation exists
has(object.metadata) && has(object.metadata.annotations) &&
  'osramp.io/sbom-url' in object.metadata.annotations

# Agent governance flag
has(agent.audit_config) && has(agent.audit_config.event_logging_enabled) &&
  agent.audit_config.event_logging_enabled == true
```
