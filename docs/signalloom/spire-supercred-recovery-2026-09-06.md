# SPIRE and SuperCred recovery evidence — 6 September 2026

## Verified runtime results

- Existing agent had zero restarts over 14 hours and logged agent SVID rotation and workload renewals.
- Primary agent ran `kubectl -n inf-bao rollout restart daemonset/spire-agent`, followed by rollout status (120-second deadline). Replacement `spire-agent-vx45n` became 1/1 Ready with zero restarts.
- After that restart, `bash scripts/supercred-demo.sh 2` exited zero. Job terminal wait completed in four seconds; SPIFFE identity, OpenBao authentication, credential retrieval and Cardvault service access completed. Raw credentials were withheld from the evidence output.

## Integration defects fixed

The runtime Job lacked `signalloom.ai/agent=true`, so the existing identity-plane egress policy did not select it. A new regression failed before this label was added.

Adding that label exposed the existing admission contract: agents must declare a framework. Admission rejected Pod creation until `signalloom.ai/framework=custom` was supplied. A second regression failed before correction; admission enforcement was not weakened.

The next runtime attempt acquired identity and passed OpenBao, but timed out contacting Cardvault. The Job manifest now also applies `allow-supercred-cardvault-egress`, selecting only Cardvault SuperCred workloads and allowing TCP/8080 only to Cardvault-labeled pods in `inf-signalloom`. No namespace-wide egress was added.

The initial test suite was subsequently revised and moved to `d2-signalloom/test/supercred-job-egress.bats`; see the independent-review follow-up for the final configuration and live negative tests.

## Remaining gates and limitations

### Explicit release decision

Andrew chose **Keep explicit release blocker** rather than installing Kyverno. No new admission controller or signature-enforcement policy will be installed under this task. Image-signature admission remains an unresolved production release requirement. This decision does not imply production readiness and does not undo the verified SPIRE/SuperCred repair.

### Independent-review follow-up

The initial generic-agent-label repair was replaced: NetworkPolicies are additive, and that label inherited unrelated peer and application grants. The final Job intentionally has no `signalloom.ai/agent` label. Its dedicated policy permits only Cardvault pods in `inf-signalloom` on TCP/8080 and OpenBao pods in `inf-bao` on TCP/8200. The real credential-chain Job completed again with this narrower configuration.

Live positive/control probes used the existing dashboard image, no service-account token mount, and no SPIRE socket. Both carried the receiving-side `bao.controlplane.io/consumer=cardvault-agent` label. Only the positive pod carried the dedicated egress policy's workload labels. Positive: HTTP200/curl exit0 for both service health endpoints. Negative: HTTP000/curl exit28 for both. This establishes network selection enforcement, not authenticated access or resistance to an actor allowed to create arbitrarily labelled pods. Four temporary probe pods (including the initial controls missing receiving labels) were deleted afterward.

The new egress suite now resides in `d2-signalloom/test/supercred-job-egress.bats` so the slice's automatic test runner discovers it. New runner-RBAC and fail-closed cleanup tests are in `d2-signalloom/test/supercred-networkpolicy-lifecycle.bats`. The latest combined focused run passed 52/52 without skips.

Runner source RBAC grants NetworkPolicy creation only in the agent namespace; Kubernetes cannot name-restrict create. Get/patch/delete are restricted to the single named policy.

### Runner deployment and execution

The owning `signalloom-infra` ResourceSet was updated while preserving its live inputs. An initial unresolved-substitution failure was corrected; final Ready=True at generation/observedGeneration 12/12. The apps artifact was published, signed and verified: `sha256:9fd5e5f3052447ecedfbcce6bdab6649dc5d5b93c43dd46052b1e3a4a50cab0a`.

Runner image `sha256:9c25b1eb40fa84bbb4cc05da5abdc32746651a1829e1e335c10fd841892ffd94` matched the running pod imageID. Host/pod script and Job-manifest hashes matched. Running `/repo/scripts/supercred-demo.sh 2` inside the runner succeeded with its actual service account, including identity, OpenBao, KV and Cardvault stages. Named policy get/patch and namespace create succeeded; patching a different policy in the agents namespace or a policy in kube-system was denied. Existing inf-bao policy permissions remain for step 1.

The bare Kind runner image is not independently signed by this local build path; signed OCI manifests do not establish image signature enforcement. This is a supply-chain production gate, not silently satisfied by artifact signing.

Read-only runtime inspection also found that Kyverno (referenced by the repository's admission demo manifests) is not installed: no CRD, controller or ClusterPolicy is present. Implementing signature-verifying admission therefore requires an additional controller and cluster-scoped policy, not a configuration toggle. The bounded proposal is runner-only enforcement in `fe-signalloom`, an explicit registry repository, signature verification against the approved trust key, and immutable digest consumption. Required negative gates are unsigned digest, tampered digest, wrong key and unavailable verifier/registry rejection; unrelated workloads must remain unaffected. Installing this component and selecting its trust root require explicit approval. This is a pre-existing production release prerequisite, not the cause of the SPIRE crash.

### Browser verification blocker

QATester attempted both the Browser skill and repository Playwright. Browser skill had no bundled Chromium. Repository Playwright found Chrome but launch failed with `EACCES: permission denied, posix_spawn '/opt/google/chrome/chrome'`. No browser navigated to the application; TLS navigation, login, rendered evidence, browser step initiation and console errors remain unverified. No screenshots exist. An execution context permitted to launch the approved browser is required; do not bypass the sandbox or claim HTTP200 as browser evidence.

- Final bounded independent source review found no new concrete blocking regression in the intended repair. It verified syntax and diff cleanliness, but did not independently rerun the recorded live probes or BATS suites.
- Dashboard-runner delivery and service-account execution are verified; browser behavior remains blocked as described above.
- Restart durability was demonstrated for the agent, not node replacement or an outage exceeding its SVID lifetime. Persistent private keys do not make consumed enrollment tokens reusable.
- Node-local hostPath is not a multi-node disaster-recovery strategy. Disk persistence does not automatically repair trust after server authority replacement.
- This estate retains demo-only credentials and plain HTTP OpenBao service access. No blanket production certification is claimed.
- Optional auto-claim used a missing service hostname in a failed intermediate run; credential-chain success alone does not validate that optional integration.
- Job admission failure currently consumes the generic terminal wait budget before surfacing failure. Better targeted admission diagnostics remain desirable.

No commits were created. Existing unrelated worktree changes were preserved.

## Final objective-to-evidence audit

| Requirement | Evidence | Verdict |
|---|---|---|
| Deploy repaired code to local Kind | Live apps Kustomization Ready=True at `latest@sha256:9fd5e5f3052447ecedfbcce6bdab6649dc5d5b93c43dd46052b1e3a4a50cab0a`; runner image/source parity checked | Verified |
| Recover actual SPIRE failure | Original unknown-authority crash recorded; stale state quarantined, disk key manager deployed, fresh attestation and workload issuance observed | Verified |
| Prevent private-key loss across restart | Agent disk directory covered by persistent mount; pinned binary configuration validation; restart followed by successful credential chain | Verified for tested restart scenario |
| Regression coverage | 52 focused checks passed without skips; earlier durability mutation harness detected 28 injected defects | Verified within named suites |
| Security boundaries | Positive/negative live network controls; runner named-policy permission checks and denied unrelated patches | Verified within tested boundaries |
| Actual SuperCred functionality | Step 2 exited zero from runner service account, not only cluster administrator | Verified CLI/runner path |
| Browser workflow | Browser launch denied before navigation | Blocked: external execution permission required |
| Production signed-image admission | Not installed; Andrew explicitly chose to retain this release blocker | Blocked by agreed scope decision |
| State remaining limitations | Node loss, expired identity, stale trust, demo credentials/HTTP, optional auto-claim and admission diagnostics listed above | Documented, not represented as solved |

Latest read-only sample: `spire-agent-9tkhb` 1/1 Running, zero restarts, age 45 minutes; runner Deployment 1/1; apps Kustomization Ready=True. `git diff --check` passed. Full production-readiness objective is **unmet/blocked**, not complete. Resuming requires a permitted browser execution context; lifting the image-admission release gate additionally requires a changed decision approving an enforcement implementation. The working repair is left deployed.
