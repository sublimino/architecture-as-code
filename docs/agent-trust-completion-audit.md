# Agent Trust Hierarchy — Completion Audit

Audit date: 2026-08-03. Baseline: `68cd589`. Worktree:
`/home/andy/src/.worktrees/osramp-demo/feat/spiffe-agent-trust-hierarchy`.

## Prompt-to-artifact checklist

| Explicit requirement | Artifact | Verified evidence |
|---|---|---|
| Security-first project proposal | `MEMORY/WORK/20260802-201549_spiffe-agent-trust-hierarchy/Proposal.md`; implementation summary in `docs/agent-trust-project-proposal.md` | Proposal covers scope, threats, production gaps, rollback, acceptance, Cofide, and Keyfactor |
| Independent adversarial critique | `MEMORY/WORK/20260802-201549_spiffe-agent-trust-hierarchy/Adversarial-Critique.md`; disposition summary in `docs/agent-trust-adversarial-review.md` | Eight reviewers, twenty severity-ranked findings, accepted/deferred/rejected rationale |
| Worktree-based implementation | feature branch `feat/spiffe-agent-trust-hierarchy` | External worktree begins at verified `68cd589` |
| SPIFFE/SPIRE hierarchy | `d2-agent-trust/contracts/topology.v1.json`, `spire-registrations.v1.json` | Four exact namespace/service-account registrations exist live |
| Tenant and project namespaces | `d2-agent-trust/manifests/boundaries.yaml`, Fleet `agent-trust.yaml` | Six labeled namespaces exist; labels survive Fleet reconciliation |
| NetworkPolicy isolation | `d2-agent-trust/manifests/policies.yaml` | Live allow/deny probes pass under enforcing kindnet |
| OpenBao supercredentials | `contracts/openbao-role-intent.sh`, `scripts/agent-trust-local.sh` | Exact-subject/audience roles, project KV policy, five-minute TTL verified live |
| External workload enrollment | `contracts/external-enrollment.v1.json` | AWS Lambda, Cloud Run, and Azure Container Apps remain credential-free modeled contracts |
| Agent-to-agent example | `proof-helper/main.go`, `a2a/service.py` | Live planner→triage SPIRE/OpenBao/Ed25519 flow passes; replay and mutation denials pass |
| Rich topology dashboard | `AgentTrustTopologyPage.tsx` | Independent QA passed desktop and 390×844, filters, inspectors, provenance, and paths |

## Command and gate evidence

| Gate | Command / evidence | Result |
|---|---|---|
| Python security contracts | `make -C d2-agent-trust test` | 8/8 pass |
| Kubernetes render | `make -C d2-agent-trust render` | pass |
| Go A2A helper | `go test ./...` in `d2-signalloom/proof-helper` | pass |
| Lifecycle, rollback, cleanup | `bats test/agent-trust-lifecycle.bats` | 12/12 pass |
| Shell quality | `shellcheck -x scripts/agent-trust-local.sh scripts/build-sign-dashboard.sh` | pass |
| Dashboard component | `bun run test -- AgentTrustTopologyPage.test.tsx` | 9/9 pass |
| Dashboard types | `bun run typecheck` | pass |
| Browser acceptance | Playwright `Agent Trust Topology exposes denied authorization evidence` | pass |
| Independent visual QA | QATester desktop plus 390×844 | pass; no defects |
| Live Flux readiness | `./scripts/agent-trust-local.sh verify` | pass |
| Live authenticated flow | `make demo-agent-trust-network-test` | pass |
| Live negative isolation | cross-project, cross-tenant, OpenBao, internet probes | pass |
| Supply-chain artifact | signed `signalloom/agent-trust@sha256:fded026...` | cosign verification pass |
| Dashboard image | signed digest `sha256:4589902...` | built, signed, loaded, browser-tested |
| Secret regression scan | added-line scan from `68cd589` | 2,149 lines; zero key/token/password findings |
| Independent code review | final Engineer review cycle | no unresolved implementation finding after restart-replay test |

## Ideal-state criteria evidence

| ISC | Evidence |
|---|---|
| 1 | Proposal states regulated-platform demonstrator outcome. |
| 2 | In-scope and out-of-scope boundaries are explicit. |
| 3 | Authentic, fixture, modeled, and production-gap states are separated. |
| 4 | Threat table covers identity, replay, isolation, keys, and deception. |
| 5 | Production gaps enumerate bootstrap, storage, TLS, CSI, cloud, and evidence. |
| 6 | Milestones and additive rollback strategy are documented. |
| 7 | Deliverables map to SMART acceptance and validation methods. |
| 8 | Cofide compatibility is a sourced design constraint, not a claim. |
| 9 | Cofide references cover Connect, trust domains, and SVID delivery. |
| 10 | Keyfactor acquisition intent and EJBCA seam are narrowly stated. |
| 11 | Olly AgentCard and deterministic authorization patterns are dispositioned. |
| 12 | Existing SPIRE/OpenBao/Dex/Signal Loom components are reused explicitly. |
| 13 | Critique identifies issuer, authority, trust-domain, and replay weaknesses. |
| 14 | Critique identifies CNI, hostPath, and broad-policy weaknesses. |
| 15 | Critique identifies provider attestation and exported-key weaknesses. |
| 16 | Critique identifies false-observation and colour-only dashboard risks. |
| 17 | Accepted findings changed proposal and implementation controls. |
| 18 | Rejected/deferred findings retain rationale and promotion conditions. |
| 19 | Feature worktree is outside repository directory. |
| 20 | Worktree baseline is verified commit `68cd589`. |
| 21 | Topology contract defines platform, tenant, project, and agent. |
| 22 | SPIFFE grammar encodes tenant and project ownership. |
| 23 | Documentation separates trust-domain identity from authorization scope. |
| 24 | `agent-trust-platform` owns shared platform boundary. |
| 25 | Two tenant-control namespaces model tenant boundaries. |
| 26 | Three project namespaces model workload boundaries. |
| 27 | Planner→triage is the sole declared cross-workload intent. |
| 28 | Cross-tenant path is denied and modeled as platform-mediated only. |
| 29 | Platform namespace has default-deny ingress. |
| 30 | Platform namespace has default-deny egress. |
| 31 | Tenant-control namespaces have default-deny ingress. |
| 32 | Tenant-control namespaces have default-deny egress. |
| 33 | Project namespaces have default-deny ingress. |
| 34 | Project namespaces have default-deny egress. |
| 35 | Explicit DNS policies target kube-dns TCP/UDP 53 only. |
| 36 | Only planner and triage manifests mount the Workload API socket. |
| 37 | Triage combines exact network source with exact SPIFFE subject. |
| 38 | OpenBao ingress selects payment namespace plus planner/triage pods. |
| 39 | Live cross-project and cross-tenant denial probes pass. |
| 40 | ResourceSet and workload manifests preserve stable namespace labels. |
| 41 | Existing SPIRE foundation serves `signalloom.demo`. |
| 42 | Join-token node-attestation limitation and PSAT target are explicit. |
| 43 | Four registrations use exact namespace/service-account selectors. |
| 44 | Planner and triage mount SPIRE sockets read-only. |
| 45 | OpenBao exact roles validate JWT-SVID subject bindings. |
| 46 | OpenBao roles bind `openbao-supercredential` audience. |
| 47 | `agent-trust-acme-payments` policy scopes one tenant/project KV prefix. |
| 48 | Live role output proves five-minute scoped Bao tokens. |
| 49 | Agent workloads never receive the OpenBao administrative token. |
| 50 | README and proposal separate SPIRE and OpenBao authority boundaries. |
| 51 | External contract covers AWS Lambda identity. |
| 52 | External contract covers Google Cloud Run identity. |
| 53 | External contract covers Azure Container Apps identity. |
| 54 | Each external contract requires provider assertion and stable binding. |
| 55 | External identity grammar remains tenant/project constrained. |
| 56 | Each external contract defines bundle rotation/reload semantics. |
| 57 | External contracts contain no cloud credentials. |
| 58 | Live planner obtains its JWT-SVID from SPIRE Workload API. |
| 59 | Live triage validates planner JWT-SVID through OpenBao. |
| 60 | Ed25519 context binds JWT, body, timestamp, nonce, and receiver instance. |
| 61 | Unauthorized project and tenant callers are runtime-denied. |
| 62 | Committed and served AgentCard bytes are equality-tested. |
| 63 | Risk-reader and investigator are explicitly labeled scaffolds. |
| 64 | Workloads run non-root, read-only, seccomp, and drop capabilities. |
| 65 | `/agent-trust-topology` route and sidebar link render live. |
| 66 | SVG and native controls render hierarchy interactively. |
| 67 | External nodes carry lower-assurance labels. |
| 68 | Identity plane visualizes SPIRE issuance relationships. |
| 69 | Identity plane visualizes OpenBao JWT exchange. |
| 70 | Network/authorization planes distinguish allow and deny. |
| 71 | Accessible controls populate persistent trust inspector. |
| 72 | Tenant, location, evidence, and decision filters are tested. |
| 73 | Page uses existing Signal Loom design tokens and components. |
| 74 | Independent QA confirms 940×590 desktop topology. |
| 75 | Focused component suite passes nine deterministic tests. |
| 76 | Gateway Playwright smoke test passes. |
| 77 | Python and BATS suites validate topology and policy contracts. |
| 78 | Live authenticated A2A positive flow passes. |
| 79 | Live unauthorized network paths fail closed. |
| 80 | Proposal and dashboard explicitly reject production-readiness claims. |
| 81 | Policy header and README separate reachability from authorization. |
| 82 | Dashboard distinguishes observed, modeled, fixture, and stale states. |
| 83 | Expired and replayed authorization contexts receive denial coverage. |
| 84 | Registration contract and live SPIRE entries bind exact selector pairs. |

## Residual promotion gates

- Replace join-token SPIRE bootstrap with Kubernetes PSAT.
- Replace raw hostPath socket delivery with SPIFFE CSI Driver plus admission policy.
- Replace dev-mode OpenBao with TLS, HA Raft, auto-unseal, and audited bootstrap.
- Persist runtime evidence through an authenticated topology API before marking edges observed.
- Implement and validate real provider attestation before promoting external workloads.
