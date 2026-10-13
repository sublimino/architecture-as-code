# Reference: The 17 Silent Failure Patterns in Signal Loom

Extracted from historical debugging sessions and platform archaeology (`Silent failure patterns found in Signal Loom.md`).

## Category 1: Two Things That Must Agree (No Checker Existed)

| # | Invariant | What Failed Silently | System Signature |
|---|---|---|---|
| 1 | Namespace agreement | Flux `targetNamespace` relocated pod; discovery code queried old namespace | "Refresh Agents" returned empty; exit 0 |
| 2 | Image transfer truth | `kind load docker-image` transferred metadata without layers | Pod `ImagePullBackOff`; `kind load` reported success |
| 3 | RBAC namespace coverage | Proxy ServiceAccount lacked read grants on target namespace | Fewer agents returned; 403 swallowed |
| 4 | Routing prefix uniqueness | Nginx proxy prefix matched React route (`/supercred/`) | Browser 301 off-origin -> `ERR_CONNECTION_REFUSED` |
| 5 | NetworkPolicy egress | Dashboard had no egress rule to reach fake integration proxy | Nginx logged 499; proxy logs empty |
| 6 | Patch index stability | Kustomize JSON6902 patch addressed `/spec/resources/N` by index; insertion shifted it | Local artifacts rejected by GitHub keys |
| 7 | Init SQL lifecycle | `/docker-entrypoint-initdb.d` runs only on empty database volume | Schema updates never applied to existing DB |
| 8 | Audit constraint agreement | PostgreSQL constraint allowed undotted names; code emitted dotted (`agent.created`) | All audit inserts failed with CheckViolation |
| 9 | JSONB serialization | List passed directly to JSONB column without `json.dumps()` | Hidden behind defect #8 |

---

## Category 2: Checks That Structurally Cannot Detect Failure

| # | Flawed Check | Why It Could Never Fail | Correct Replacement |
|---|---|---|---|
| 10 | `readyExpr: status.observedGeneration >= 0` | Trivially true the microsecond any Kubernetes object is created | Check real sub-conditions (`status.conditions`) |
| 11 | `kubectl wait --for=condition=ready deploy/x` | Deployments have NO Ready condition (only Available/Progressing) | Use `scripts/lib/wait.sh` `wait_rollout` |
| 12 | `[ "$status" -ne 0 ]` on distroless exec | Container lacks shell; exec always fails, passing negated condition | Assert positive observable output from outside pod |
| 13 | Flux missing `substituteFrom` token | Token left literal (`${VAR}`); apply succeeds 200 | Scan applied yaml for unexpanded `${` tokens |
| 14 | FAIR percentile clamp (`var95 < ale`) | Clamped percentile up to mean; reported fabricated risk | True statistical distribution without heuristic clamps |
| 15 | `make images` | Built only 2 of 5 slices; reported success | Build targets explicitly verifying all sub-images |
| 16 | `make test` | Ran only 8 of 43 BATS files; 15 files never referenced | Derivation tests scanning directory for all `.bats` |
| 17 | Symmetric PERT triple -> `NaN` | `alpha <= 0` didn't catch `NaN`; while loop spun infinitely | Explicit `math.isnan()` check on input parameters |
