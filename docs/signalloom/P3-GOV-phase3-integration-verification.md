# SLDPB25-P3-GOV Phase 3 Integration Verification

## Scope and immutable boundaries

Governor review executed against integration revision
`360bb29b58c3f182691d4c9173eb1ddfadc00f88` on
`integration/signalloom-d2-v2.5.0`. No `board.json` or Kanban runtime record
was modified. No branch switch, rebase, merge, push, pull request, production
credential, production cutover, external integration, or data migration was
performed.

The integration branch was already at the accepted TEST-1 convergence commit;
no implementation branch was merged by this Governor. The recorded P3-1 commit
`45486026b8f6273ceb3933fb6f6bae2bfb6fe3aa` exists but is not an ancestor of
the integration revision (`git merge-base --is-ancestor ... HEAD`: exit 1), so
it was not accepted or merged as a standalone change. Current routing files
remain present at the integration revision and are assessed only by current
test evidence below.

## Dependency evidence

| Dependency | Claimed evidence | Current reachability | Governor disposition |
| --- | --- | --- | --- |
| P3-1 routing | `45486026b8f6273ceb3933fb6f6bae2bfb6fe3aa` | Object exists; not ancestor of current integration HEAD | Not accepted as a merge candidate. |
| P3-2 TEST-1 | `360bb29b58c3f182691d4c9173eb1ddfadc00f88` | Current integration HEAD | Present, but full-suite revalidation failed. |

The current tree contains the required route and policy surface:
`d2-signalloom/apps/fe-signalloom/base/gateway-route.yaml`,
`d2-signalloom/apps/fe-signalloom/base/networkpolicy.yaml`,
`d2-signalloom/test/gateway-routing.bats`, and
`d2-signalloom/test/runtime.bats`.

## Full-suite execution

Declared command:

```text
env LC_ALL=C LANG=C make demo-signalloom-test-1
```

Execution exit: **2**. The command was run once from a clean-at-HEAD detached
copy of the same `360bb29` integration revision; that copy held only an
untracked Governor PRD. The registered integration worktree was not used for
test execution because it already contained unrelated tracked and untracked
runtime changes.

| Stage | Exit | Disposition |
| --- | ---: | --- |
| Static topology, Gateway, probes, Dex, policy contracts | 2 | Dependent infrastructure defect. |
| API contracts and persistence | 1 | Dependent API-contract regression. |
| Deterministic fake integrations | 0 | Pass. |
| Dashboard API ownership contract | 0 | Pass. |
| TEST-1 harness contract | 1 | Dependent TEST-1 harness expectation drift. |
| Flux and workload convergence | 2 | Dependent local-runtime prerequisite defect. |
| Gateway, probes, Dex, NetworkPolicy runtime negatives | 1 | Dependent route/runtime defect. |
| Dex and dashboard journey matrix | 1 | Dependent browser-tooling and runtime prerequisite defect. |

## RETEST-1 defect classification

| ID | Reproduce | Exit | Evidence | Owner before RETEST-1 |
| --- | --- | ---: | --- | --- |
| P3G-1 | `make -C d2-signalloom test` | 2 | Curl connection reset during static topology/Gateway/Dex policy stage. | Routing/runtime implementation owner. |
| P3G-2 | `cd d2-signalloom/apps/fe-signalloom/src && uv run --python 3.12 --with pytest --with pytest-asyncio --with-requirements requirements.txt python -m pytest tests -q` | 1 | Seven API compatibility failures: missing `tenant_id`, incompatible agent response, absent `build_agents_response`, and OpenAPI mismatch. | API compatibility owner. |
| P3G-3 | `bats test/signalloom-test-1-harness.bats` | 1 | Harness expected subordinate results to be zero; aggregate now reports dependent failures. | TEST-1 harness owner. |
| P3G-4 | `make demo-signalloom-test` | 2 | Flux/workload stage reports connection reset. | Local lifecycle/runtime owner. |
| P3G-5 | `bats d2-signalloom/test/runtime.bats d2-signalloom/test/test-1-runtime.bats` | 1 | Expected unauthenticated API response was not 401/403. | Gateway/API runtime owner. |
| P3G-6 | `make demo-signalloom-test-1` | 1 stage | Seven Kind images missing, Olly/Frontend/Backend namespaces absent, three port-forwards exited, and Playwright reported unknown `test` command. | Local lifecycle and browser harness owners. |

These are qualifying dependent-retest defects, not waivers. `RETEST-1` must add
regression coverage only after each owning implementation/runtime defect is
resolved and the full suite exits zero. Phase 3 is **fail / no-go**; P4 must not
advance from this evidence.

## Evidence commands

```text
git merge-base --is-ancestor integration/signalloom-d2-v2.5.0 HEAD  # 0
git cat-file -e 45486026b8f6273ceb3933fb6f6bae2bfb6fe3aa^{commit} # 0
git merge-base --is-ancestor 45486026b8f6273ceb3933fb6f6bae2bfb6fe3aa HEAD # 1
git merge-base --is-ancestor 360bb29b58c3f182691d4c9173eb1ddfadc00f88 HEAD # 0
env LC_ALL=C LANG=C make demo-signalloom-test-1 # 2
```
