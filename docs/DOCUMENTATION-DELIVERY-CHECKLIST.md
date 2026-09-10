# Documentation Delivery Checklist

This checklist maps the requested outcomes to repository artifacts and verified
evidence. Verification was performed on 9 September 2026.

| Requested outcome | Artifact or evidence | Status |
| --- | --- | --- |
| Review documentation correctness | [`DOCUMENTATION-AUDIT.md`](DOCUMENTATION-AUDIT.md) maps claims to commands, manifests, workflows, and tests. | Verified |
| Review repository coverage | The audit covers root guides, each delivery slice, GCP, CI, Terraform, and user journeys. | Verified |
| Review consistency and conflicts | Fleet deployment, workflow-trigger, Go-version, Trivy, and acceptance-registry conflicts were corrected. | Verified |
| Review repetition | `TESTING.md` now links to `SPEC-REGISTRY.tsv` instead of copying volatile assignments. | Verified |
| Review information architecture | The audit defines separate user, operator, engineering-record, and evidence surfaces. | Verified |
| Review human navigation | `docs/README.md` links the user service, audit, writing rules, collaborator record, and proposal. | Verified |
| Review links and anchors | A maintained-Markdown scan checked 185 relative links and found zero broken targets or anchors. | Verified |
| Use appropriate Mermaid diagrams | The service contains an evidence-flow diagram and a stun sequence; the audit and proposal contain architecture and delivery flows. | Verified |
| Read STE-Code prompt lines 1–100 | The raw upstream source was fetched; the excerpt starts with the Level 5 word rules and three terminology gates. | Verified |
| Index STE-Code prompt lines 1–100 | The excerpt was stored in the session knowledge index under `STE Code first 100 lines`. | Verified |
| Apply adapted documentation rules | [`documentation-style.md`](documentation-style.md) records the local controlled-language rules and exceptions. | Verified |
| Inspect native-cloud | [`../d2-signalloom/apps/docs-signalloom/README.md`](../d2-signalloom/apps/docs-signalloom/README.md) records the inspected relationship and licensing boundary. | Verified |
| Create user-facing documentation service | `d2-signalloom/apps/docs-signalloom/` contains the Astro Starlight source, lock file, nginx configuration, and Dockerfile. | Verified |
| Use a separate container | `docs-deployment.yaml` defines an independent hardened workload and `docs-service.yaml` defines its Service. | Verified |
| Deploy at `/docs` | `signalloom-docs` is accepted by Envoy; the deployed landing and Quick start routes returned HTTP 200 on port 18443. | Verified |
| Keep assets below `/docs` | Astro builds with `base: "/docs"`; browser QA found no escaped same-origin links or failed assets. | Verified |
| Provide Quick start | `start/quick-start.md` uses verified repository lifecycle commands and access paths. | Verified |
| Provide first-agent onboarding | `start/first-agent.md` covers prerequisites, registration, verification, and current persistence limits. | Verified |
| Provide stunning and unstunning | `operate/stun-agent.mdx` covers hazard, action, restoration labels, evidence, and authorization limits. | Verified |
| Provide superadmin demos | `demos/superadmin.md` covers prerequisites, five phases, dashboard execution, evidence, and recovery. | Verified |
| Provide view-only workflow | `roles/view-only.md` describes the read journey and states that enforcement is not implemented. | Verified |
| Provide advanced workflow | `roles/advanced.md` describes current operator access and the unimplemented role contract. | Verified |
| Provide security-team workflow | `roles/security-team.md` describes evidence review and optional KubeSec-AFM use. | Verified |
| Provide platform-admin workflow | `roles/platform-admin.md` describes estate commands and the current identity boundary. | Verified |
| Identify roadmap items and TODOs | `reference/roadmap.md` separates available behaviour, authorization gaps, onboarding work, simulations, and later work. | Verified |
| Write next-work proposal | [`FIRST-USER-ONBOARDING-PROPOSAL.md`](FIRST-USER-ONBOARDING-PROPOSAL.md) covers standard, superadmin, advanced, and shared usability work. | Verified |
| Avoid the prohibited phrase | Repository search found zero occurrences after proposal creation. | Verified |
| Inspect KPAI help and tests | [`COLLABORATOR-REVIEW.md`](COLLABORATOR-REVIEW.md) records the inspected wrapper, options, probe, and test runner. | Verified |
| Invoke KPAI one-shot | The bounded read-only invocation selected its profile, then its drift guard failed closed before inference. | Verified invocation; no model result |
| Inspect Antigravity help and tests | The collaborator record covers `agy` print mode, JSON output, grants, wrappers, and resume behaviour. | Verified |
| Invoke Antigravity one-shot | The bounded read-only invocation selected its profile, then profile inheritance failed before inference. | Verified invocation; no model result |
| Synthesize shared intelligence | The collaborator record reports only supported operational conclusions and does not fabricate model consensus. | Verified |

## Verification evidence

- Astro checks: 0 errors, 0 warnings, 0 hints.
- Static site build: 13 generated pages.
- Package audit: 0 vulnerabilities.
- Docs, staleness, and acceptance-registry BATS checks: 37 passed.
- Container scan: 0 High or Critical vulnerabilities.
- Runtime hardening: non-root user, read-only root, dropped capabilities,
  RuntimeDefault seccomp, bounded temporary storage, and no service-account token.
- Supply chain: SPDX SBOM, SLSA provenance, digest, and Cosign signature verified.
- Runtime identity: `check-deployed-staleness.sh docs-signalloom` reported the
  running Pod fresh against the working tree.
- Gateway status: `Accepted=True` and `ResolvedRefs=True`.
- Browser QA: all requested navigation, Mermaid, mobile, keyboard, console,
  asset, CSP, and 404 checks passed.

The repository Playwright process could not launch Chrome inside the current
outer sandbox because GPU and configuration paths were denied. Its request-only
404 assertion passed. An independent QATester launched Chromium in its supported
browser environment and passed the complete deployed-Gateway journey. The
acceptance registry check proves that `docs.spec.ts` is assigned to CI stage 8b.
