# SLAC Phase 2 Governor Evidence

**Logical ID:** SLAC-P2-GOV  
**Status:** FAIL  
**Phase 3 may proceed:** No  
**Created:** 2026-09-09 00:13:30+01:00  
**Source branch:** `integration/slac-v0.1.0`  
**Source commit:** `ccf6e10541a6658136a33f455eb147223faae920`  
**Governor worktree:** `/home/andy/src/.worktrees/osramp-demo/slac-v0.1.0/governor`

## Executive verdict

The production dashboard build passes, but Phase 2 cannot be sealed. The exact required `bun test` command invokes Bun's native test runner rather than Vitest. It did not complete: Bun 1.4.0 consumed 29.65 GB peak RSS, emitted 1.58 GB of output, then crashed. A bounded independent reproduction exits 1 immediately because Bun's Vitest compatibility surface does not implement `vi.hoisted`; the dashboard has 29 usages across its Vitest suites. The required 100% frontend test pass rate therefore has no valid evidence.

The current production bundle also grows relative to a reproducible build of the P2-PRE source under the identical installed toolchain. Consequently, the required zero-regression bundle statement would be false.

## Prompt-to-artifact checklist

| Requirement | Evidence | Result |
|---|---|---|
| Dedicated governor worktree | PWD and repository toplevel both matched the declared governor path | PASS |
| Required integration branch | Branch and integration ref resolved to `ccf6e10541a6658136a33f455eb147223faae920` | PASS |
| P2-1 integrated before P2-2 | `dd6680c15473cb9c27cae1bc4e840e1ec42d23f9` is the parent of P2-2 HEAD | PASS |
| `bun run build` exit 0 | Complete output below; 12,060 ms; raw log SHA-256 `504274168c86622de7a11a9f98aa2c2d5f5c94152b64914150296bbe7cb35059` | PASS |
| Production artifact inventory | Vite emitted `index.html`, CSS, image assets, route chunks, and entry chunks | PASS |
| `bun test` exit 0 | Exact command crashed after 117,744 ms; bounded reproduction exits 1 | FAIL |
| Complete Vitest 100% pass log | Impossible to produce through the mandated native Bun runner | BLOCKED |
| Auto-Claim interaction coverage | Existing interaction tests cover inventory, overview, access, pending, success, failure, retry, and stale-poll states | PRESENT, NOT REGATED |
| Discovered-agent fixtures | `fakeData.ts` exports claimable and claimed fixtures consumed by three component/page suites | PRESENT, NOT REGATED |
| `bun x tsc --noEmit` | Not run after the required test gate failed | NOT RUN |
| ESLint audit | Not run after the required test gate failed | NOT RUN |
| Browser regression audit | Not run after the required test gate failed | NOT RUN |
| Zero bundle size regressions | Reproducible comparison records increases in total JavaScript and named route chunks | FAIL |

## Execution identity

The build execution digest is SHA-256 `474d7ffc0cd818a79188babeac25a660c7daac6f366e0ba0f595dcd48faeda7b`. It binds source commit, command, start, end, duration, exit code, and raw-log digest.

The failed Bun execution digest is SHA-256 `4972a4f420f5d1476fd8e51ae0abff5804e547a7c9bc333316a709eb2e95cbf6`. It binds source commit, exact command, measured duration, abnormal termination, and raw-log digest.

## Complete production build log

Command: `cd d2-signalloom/apps/dashboard-signalloom && bun run build`  
Started: `2026-09-09T00:00:14+01:00`  
Finished: `2026-09-09T00:00:26+01:00`  
Measured duration: `12060 ms`  
Exit code: `0`

```text
$ tsc && vite build
The CJS build of Vite's Node API is deprecated. See https://vite.dev/guide/troubleshooting.html#vite-cjs-node-api-deprecated for more details.
vite v5.4.21 building for production...
transforming...
✓ 1245 modules transformed.
rendering chunks...
computing gzip size...
dist/index.html                                       2.45 kB │ gzip:   1.16 kB
dist/assets/okta-BfL8j98Q.png                        11.01 kB
dist/assets/aws-BY2Jc5Lp.png                         17.41 kB
dist/assets/gcp-DjJ9CN-r.png                         24.92 kB
dist/assets/openai-7d9-6SPQ.png                      63.19 kB
dist/assets/entra-BBQfgFrR.png                       69.20 kB
dist/assets/signal-loom-logo-BmqfxYgS.png            79.83 kB
dist/assets/AgentTrustTopologyPage-Bk-Jalni.css       4.82 kB │ gzip:   1.42 kB
dist/assets/index-0OH4glcJ.css                       10.43 kB │ gzip:   2.80 kB
dist/assets/style-BnuhLJ6X.css                       15.87 kB │ gzip:   2.67 kB
dist/assets/tokens-Ccm6jg91.js                        0.25 kB │ gzip:   0.18 kB
dist/assets/proofQuery-BmL7N2bV.js                    0.40 kB │ gzip:   0.29 kB
dist/assets/ConversionNote-D5Q76jTw.js                0.41 kB │ gzip:   0.33 kB
dist/assets/tooltipContext-zw22uyug.js                0.54 kB │ gzip:   0.29 kB
dist/assets/agentClaim-Bz81gvXK.js                    0.56 kB │ gzip:   0.40 kB
dist/assets/demoRunPresentation-BYll94tb.js           0.98 kB │ gzip:   0.61 kB
dist/assets/weaveApi-brDGQDS3.js                      1.05 kB │ gzip:   0.48 kB
dist/assets/ButtonWait-BMDFOunN.js                    1.22 kB │ gzip:   0.49 kB
dist/assets/agentMatching-DWSu8NIx.js                 1.31 kB │ gzip:   0.54 kB
dist/assets/EmptyState-Ctm2MtvZ.js                    1.34 kB │ gzip:   0.55 kB
dist/assets/signalFusionDemo-CL4Txrea.js              1.41 kB │ gzip:   0.64 kB
dist/assets/ProviderLogo-DceRjwM2.js                  2.15 kB │ gzip:   1.03 kB
dist/assets/ErrorState-C2tHD8zg.js                    2.30 kB │ gzip:   0.87 kB
dist/assets/TriageMenu-dTifC4-J.js                    2.88 kB │ gzip:   0.96 kB
dist/assets/useSignalSummary-DOtAscNX.js              3.20 kB │ gzip:   1.51 kB
dist/assets/HelpHint-PYUNYdwB.js                      3.39 kB │ gzip:   1.48 kB
dist/assets/DonutChart-w7p-kGGN.js                    3.59 kB │ gzip:   0.97 kB
dist/assets/StatusBadge-DkwrHyhN.js                   4.20 kB │ gzip:   1.07 kB
dist/assets/DataTableToolbar-BKyMoE14.js              4.20 kB │ gzip:   1.20 kB
dist/assets/CredentialStateNotice-D-rN-IjZ.js         4.66 kB │ gzip:   1.14 kB
dist/assets/PageToc-BeAwOoCo.js                       5.25 kB │ gzip:   2.02 kB
dist/assets/ProofConsole-Co4I5D8A.js                  5.41 kB │ gzip:   1.45 kB
dist/assets/agentQuerySelectors-CY_rsIbH.js           5.55 kB │ gzip:   1.44 kB
dist/assets/DashKit-DTEAwGTa.js                       5.57 kB │ gzip:   1.26 kB
dist/assets/AgentDeepLink--xhAIEzT.js                 6.30 kB │ gzip:   2.15 kB
dist/assets/afmApi-CmL1KZsV.js                        6.87 kB │ gzip:   2.30 kB
dist/assets/LoadingState-byH1BKe2.js                  7.18 kB │ gzip:   1.79 kB
dist/assets/CookieSettingsModal-DUN79iWl.js           8.25 kB │ gzip:   1.85 kB
dist/assets/DataTable-9EozMklR.js                     8.61 kB │ gzip:   2.08 kB
dist/assets/AddClusterModal-DrbqtCuA.js               8.96 kB │ gzip:   1.81 kB
dist/assets/jsx-runtime-C05ayHi0.js                  12.47 kB │ gzip:   5.00 kB
dist/assets/value-UZnMZcxy.js                        12.76 kB │ gzip:   5.23 kB
dist/assets/demoRunner-tcXfgmOd.js                   13.23 kB │ gzip:   4.40 kB
dist/assets/RedeemInvite-BA2QjaBh.js                 13.41 kB │ gzip:   2.55 kB
dist/assets/FrameworkDetailPage-Bt_Ovb2l.js          14.55 kB │ gzip:   3.22 kB
dist/assets/SignalStorePage-53j0I7s7.js              19.01 kB │ gzip:   3.30 kB
dist/assets/DiscoveryAccountDetailPage-Cn0tktpI.js   20.26 kB │ gzip:   3.13 kB
dist/assets/AgentPosturePage-iWfBVsGZ.js             25.07 kB │ gzip:   4.78 kB
dist/assets/AuditTrailPage-DBC7_kTN.js               26.93 kB │ gzip:   6.18 kB
dist/assets/SignalFusionPage-De9d8536.js             29.77 kB │ gzip:   5.77 kB
dist/assets/DistanceLatencyPage-DA6KYu4M.js          31.54 kB │ gzip:   6.02 kB
dist/assets/RbacAnalysisPage-CixQwzDy.js             32.07 kB │ gzip:   7.68 kB
dist/assets/CompliancePolicyPage-Cf-m0bD7.js         35.26 kB │ gzip:   9.60 kB
dist/assets/FederatedServicesPage-BwJ9z6Dq.js        36.74 kB │ gzip:   6.95 kB
dist/assets/DiscoveryPage-BStNGX3k.js                37.22 kB │ gzip:   6.23 kB
dist/assets/RiskExposurePage-DlTI7FKg.js             37.70 kB │ gzip:   8.96 kB
dist/assets/NetworkTestsPage-CcJCr6Ix.js             39.06 kB │ gzip:   7.81 kB
dist/assets/CompliancePage-Bo-Y6DZG.js               45.17 kB │ gzip:  11.31 kB
dist/assets/CredentialInventoryPage-7gPeiZow.js      47.49 kB │ gzip:   9.28 kB
dist/assets/SettingsPage-CE-JllmS.js                 53.81 kB │ gzip:   8.16 kB
dist/assets/CryptographyPage-t8EukakD.js             53.86 kB │ gzip:  10.47 kB
dist/assets/FleetDemoPage-DzYptmE6.js                58.93 kB │ gzip:  12.48 kB
dist/assets/RbacExplorerPage-CJ9IBKiD.js             60.21 kB │ gzip:  11.99 kB
dist/assets/CollusionAccessPage-BZ9LsY8i.js          61.93 kB │ gzip:  12.32 kB
dist/assets/CartesianChart-DkIUunA7.js               70.66 kB │ gzip:  17.90 kB
dist/assets/WeavePage-DAY6XNEJ.js                    71.77 kB │ gzip:  10.68 kB
dist/assets/AgentTrustTopologyPage-BpPx7AuB.js       72.42 kB │ gzip:  14.12 kB
dist/assets/OnboardingWizard-7FBSf7QX.js             74.59 kB │ gzip:  10.96 kB
dist/assets/DesignSystemHeadersPage-DNlK0qqv.js      96.43 kB │ gzip:  15.12 kB
dist/assets/SuperCredPage-DQuESceL.js               110.26 kB │ gzip:  18.23 kB
dist/assets/DesignSystemPage-BEp0RUf8.js            111.02 kB │ gzip:  20.31 kB
dist/assets/AgentsPage-DGqvwJmn.js                  140.61 kB │ gzip:  21.17 kB
dist/assets/style-C4bZaFwt.js                       172.87 kB │ gzip:  55.34 kB
dist/assets/ConnectorHelpPage-Be4HBcr8.js           206.01 kB │ gzip:  61.54 kB
dist/assets/CategoricalChart-BhXH5pIp.js            284.30 kB │ gzip:  87.76 kB
dist/assets/AgentDetailPage-CUjo6Bx1.js             307.35 kB │ gzip:  38.69 kB
dist/assets/index-JLh_-vH6.js                       699.27 kB │ gzip: 195.60 kB

(!) Some chunks are larger than 500 kB after minification. Consider:
- Using dynamic import() to code-split the application
- Use build.rollupOptions.output.manualChunks to improve chunking
- Adjust chunk size limit for this warning via build.chunkSizeWarningLimit.
✓ built in 3.83s
```

## Required test command failure

Command: `cd d2-signalloom/apps/dashboard-signalloom && bun test`  
Observed runner: Bun native test runner `1.4.0`, not Vitest  
Measured runner time before crash: `117744 ms`  
Resource peak: `29.65 GB RSS`  
Raw output: `1,577,273,495 bytes`, `12,942,135 lines`  
Raw-log SHA-256: `4e8d0e954ef11b26ae3f56d309c25d365cbaec171abf03b364c01badbc993ee8`  
Termination: Bun panic after the command exceeded the 120-second command guard; no exit-code-zero result exists.

The full 1.58 GB crash log is intentionally not committed. Committing it would be disproportionate and would not provide the requested passing Vitest evidence. The bounded reproducer below is complete.

### Complete bounded reproduction

Command: `bun test --bail=1 --max-concurrency=1`  
Exit code: `1`

```text
bun test v1.4.0 (34cbb9a40)

src/App.test.tsx:

# Unhandled error between tests
-------------------------------
 8 | // The bug this file pins: clicking Compliance showed a rotating ring (App's
 9 | // own private `Spinner`) while the route chunk downloaded, and only then the
10 | // Signal Loom loader once the page mounted. Two loading idioms back to back.
11 | // The Signal Loom mark is now the only one, at both of App's waits.
12 |
13 | const auth = vi.hoisted(() => ({
                     ^
TypeError: vi.hoisted is not a function.
      at src/App.test.tsx:13:17
-------------------------------

Ran 2 tests across 2 files. [610.00ms]
Bailed out after 1 failure
```

Repository search finds 29 `vi.hoisted` references across the dashboard's Vitest test files. Independent QATester execution reproduced exit code 1 and concluded that direct `bun test` cannot truthfully be accepted as a complete Vitest run.

## Bundle comparison

The documentary P2-PRE proof reported smaller wildcard chunk sizes, but did not bind them to an immutable source SHA or exact dependency tree. To avoid relying on weak evidence, the governor rebuilt source commit `a3f1e9968177bfb25b5a2a370e9d0612b9fade1c` from a Git archive using the same installed `node_modules`, Bun 1.4.0, TypeScript 5.9.3, and Vite 5.4.21 as the current build.

| Metric | Rebuilt P2-PRE | Current P2-GOV | Delta |
|---|---:|---:|---:|
| Total JavaScript | 3,038,024 bytes | 3,345,744 bytes | +307,720 bytes (+10.13%) |
| `AgentsPage` raw | 114.36 kB | 140.61 kB | +26.25 kB (+22.95%) |
| `AgentsPage` gzip | 19.50 kB | 21.17 kB | +1.67 kB (+8.56%) |
| `AgentDetailPage` raw | 246.76 kB | 307.35 kB | +60.59 kB (+24.55%) |
| `AgentDetailPage` gzip | 34.96 kB | 38.69 kB | +3.73 kB (+10.67%) |
| Entry chunk raw | 676.92 kB | 699.27 kB | +22.35 kB (+3.30%) |
| Entry chunk gzip | 195.19 kB | 195.60 kB | +0.41 kB (+0.21%) |

Both baseline and current builds emit Vite's greater-than-500-kB chunk warning. The current build therefore does not establish the required zero-regression result.

## Corrective action required

1. Replace the contradictory direct-Bun gate with explicit non-watch Vitest execution, for example `bun run test --run`, or deliberately port the complete suite to Bun's native APIs.
2. Define an approved bundle budget and comparison basis. If literal zero growth remains required, optimize or split the P2 route chunks before re-running the governor.
3. Re-run the complete governor contract only after those two blockers are resolved.
