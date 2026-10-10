# Framework Pack Conformance Contract

Every CEL check in a framework pack is proven by fixtures. A check is
"correct" when a fixture that should fail it fails, a fixture that should
pass it passes, and the test that says so is shown to bite by mutation.

The harness is `d2-signalloom/apps/policy-engine/frameworks_conformance_test.go`.
Run it with:

```bash
cd d2-signalloom/apps/policy-engine && go test -run 'TestConformance' -v .
```

## Input bindings

The policy engine evaluates every check against three CEL variables. A check
may read any of them. Fixtures supply them under `input`.

| Variable  | Shape | Source in production |
|-----------|-------|----------------------|
| `object`  | A Kubernetes **Pod-shaped** object: `{"apiVersion","kind","metadata":{...},"spec":{...}}`. Checks read `object.spec.*` and `object.metadata.*`. For a Deployment/Job, the scanner passes the pod template as `{"metadata": template.metadata, "spec": template.spec}`. The scanner **MUST** copy the workload's namespace into `object.metadata.namespace` (a pod template carries none of its own). Controller-level facts (`replicas`, update strategy, PDBs) are **not** in this object: a check that needs them is not evaluable from a pod and is marked `status: placeholder` in its pack (it reports `not_evaluated`). | The workload's pod spec. Scan field `object` (alias `manifest`). An empty `object` (`{}`) is treated as absent, so it never masks a non-empty `manifest`. |
| `agent`   | The **agent context document**: governance facts about the AI agent the workload runs. Field paths are owned by the pack that reads them and documented in that pack's `AGENT-CONTEXT.md`. | Assembled by fe-signalloom from the agent registry. Scan field `agent`. |
| `request` | A runtime request context (tool call, peer identity, network). | Scan field `request`. |

`manifest` is bound to the same value as `object` for backward compatibility.
Unbound variables are bound to an empty map, never left undeclared.

Numbers arrive as JSON numbers decoded by Go's `encoding/json` (float64). Write
numeric comparisons that hold for both int and double (`c.securityContext.runAsUser > 0`
is fine; test it with a fixture).

## Verdicts

| Verdict | Meaning |
|---------|---------|
| `pass`  | The expression evaluated to `true`. |
| `fail`  | The expression evaluated to `false`. |
| `error` | The expression could not evaluate (missing key, type error, non-bool). |
| `not_evaluated` | The check (or its framework) has `status: placeholder`. The expression is never run; `passed` is `false` and there is no `error`. The summary counts it in `totalControls` and `notEvaluated` only, never in `failed`, `errored` or exposure. |

**`error` is never a `fail`.** A check that errors on an ordinary, valid input
is a defect in the check: guard optional fields with `has()` and decide the
absent-field semantics explicitly (e.g. absent `automountServiceAccountToken`
means the Kubernetes default `true`, so the CIS check fails, not errors).

## Fixtures

Location: `policy/frameworks/<framework-id>/<version>/fixtures/**/*.json`.
One fixture per file. Schema:

```json
{
  "name": "pod-container-runs-as-root",
  "level": "unit",
  "description": "One container sets runAsUser 0 with no runAsNonRoot.",
  "input": {
    "object":  { "apiVersion": "v1", "kind": "Pod", "metadata": {"name": "x"}, "spec": {"containers": []} },
    "agent":   {},
    "request": {}
  },
  "expect": {
    "<check-id>": "fail"
  }
}
```

Rules the harness enforces:

1. `name` is unique within the pack and equals the file's basename without `.json`.
2. `level` is `unit` or `integration`.
3. `expect` is non-empty and every key is a check ID that exists in the pack.
4. A `level: integration` fixture lists an expectation for **every** check in the
   pack (the complete verdict vector), so one realistic input pins all checks at once.
5. Every check whose `status` is not `placeholder` has at least one `pass` and
   at least one `fail` expectation across the pack's fixtures (coverage gate).
6. An `error` expectation is allowed only for deliberately malformed input and
   the fixture's `description` must say why.
7. Every check expression compiles.

Unit fixtures are minimal: change one fact relative to a compliant baseline so
the expectation is attributable to that fact. Integration fixtures are
realistic: multi-container workloads, real Helm-chart-shaped pods, a fully
described agent.

## Proving a test bites

For every new check or fixture, record in the commit body or the worker report:

- **mutation**: the change made to the CEL (or fixture) and the failing harness
  line it produced;
- **fix**: the restoration and the passing run.

Restore mutated files from an explicit backup copy (`cp f /tmp/f.bak` ...
`cp /tmp/f.bak f`), never from the git index.

## Pack ownership

| Pack | Owner of field paths |
|------|----------------------|
| `cis-kubernetes` | `object` only |
| `finos-aigf` | `agent` paths listed in `finos-aigf/v1.0/AGENT-CONTEXT.md` |
| others | as written in each pack; `agent`/`request` paths documented in the pack's `AGENT-CONTEXT.md` when added |

Field paths already shipped are frozen: extend, never rename.
