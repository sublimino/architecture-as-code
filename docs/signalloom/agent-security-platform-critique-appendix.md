# Appendix B — Adversarial critique & open questions (Signal Loom Agent Security Platform)

<!-- machine-tag: SLASP-CRITIQUE-APPENDIX-2026-07-28 -->

Companion to `signal-loom-agent-security-platform-proposal.md`. Produced by a 25-agent adversarial critique
pass (one Principal-level critic per capability area + five strategic lenses), each of which read
the proposal and the underlying code. Findings are **deliberately harsh** — the point is to find
what a bank CISO, a sceptical EU-AI-Act/DORA auditor, and a capable attacker would find first.
Several critics inspected the actual estate and found that named "controls" are currently mocks or
cooperative disciplines; those are the highest-value findings and are flagged in the synthesis.

## B.0 — Cross-cutting synthesis (the ten findings that matter most)

1. **Governance ≠ security: registration is not provably mandatory.** The lifecycle state-machine
   governs only agents that opt in. Unless SVID/OBO issuance, the MCP gateway, and admission control
   hard-deny any unenrolled identity, an adversary simply never registers — "governance theatre."
   *(→ make enrolment a precondition of action; purple-team prove it.)*
2. **Discovery completeness is unprovable and structurally eroding.** The ≥95% KPI is scored against a
   *seeded* estate; it says nothing about serverless/embedded/SaaS-managed/cardless agents — the very
   population you are buying this to find. *(→ red-team discovery test with hidden agents; publish a
   completeness ceiling.)*
3. **Several flagship controls are currently mocks or plaintext, not cryptographic controls.** Agent-card
   "tamper detection" is a plaintext field diff (`verifyLive`) over unsigned JSON; the Cryptography/PQC
   page and the Collusion engine are hardcoded mock constants; the HITL `approved_by` is a free-text
   claim. Demoing the code collapses confidence in the other areas. *(→ sign cards to the SVID; ship a
   real crypto/collusion engine or honestly demote to TRL-2 research.)*
4. **The killswitch — the headline differentiator — is the weakest technical claim.** "Proven denial in
   ≤30s" spans five eventually-consistent planes (mesh xDS, SVID TTL, OpenBao lease, MCP session, cloud
   runtime) with no consistency guarantee; bearer JWTs/SVIDs stay valid until expiry; and there is **no
   enforcement primitive for cloud-runtime agents at all**. *(→ per-plane denial matrix with two numbers:
   guaranteed-denial and worst-case-residual; short TTLs + denylist.)*
5. **Shared-secret HS256 collapses the authorization threat model.** The "narrow-only" AuthZ-CTX is a
   cooperative discipline signed with one estate-wide symmetric secret every agent holds — a single
   prompt-injected agent (the platform's own headline threat) can forge a *wider* context. *(→ asymmetric
   per-workload signing bound to SPIFFE SVIDs; verifiable delegation chain.)*
6. **"Regulatory Immunity" is legally indefensible and an auditor red flag.** EU AI Act (Art 16/26) and
   DORA (Art 5) impose non-transferable obligations on the regulated entity; no product confers immunity.
   Self-graded "mock auditor" KPIs are unfalsifiable. *(→ kill the term; reframe as auditable evidence
   generation that reduces cost/time to demonstrate compliance; get real assessor validation.)*
7. **Commercially non-fundable as written: no buyer, no price, no ROI.** Finances are three "TBD" lines.
   *(→ signed design-partner LOI / paid pilot from the ARC client with a price and a 90-day first-value
   milestone before build approval.)*
8. **"First agent security control plane" is falsifiable and invites demolition.** Wiz (AI-SPM), Palo
   (Prisma AIRS + Protect AI), CrowdStrike, and hyperscaler-native guardrails already discover agents and
   gate their own runtimes. Breadth is not a moat. *(→ narrow to a defensible wedge: the cryptographically-
   attested, single-query "who authorized this agent action?" + independent-of-the-estate evidence.)*
9. **The control plane is the highest-value target and under-defended per-area.** Poison the inventory,
   forge a card, flip a risk class down, tamper the trail once it leaves the platform into mutable
   Splunk/ServiceNow. *(→ signed transitions, external attestation at write-time, quorum on classification
   changes, immutable evidence store the customer cannot mutate.)*
10. **Standards churn (A2A/MCP/ADK/OCSF) is a live rework risk.** The HITL gate is welded to ADK's
    `require_confirmation`; OCSF has no agent-domain event classes; A2A/MCP are young. *(→ version the
    schemas you own; abstract the runtime bindings behind adapters; publish the event-schema contract.)*

**Net.** The defensible product is *not* "we do all 20 things." It is the **attested, tamper-evident,
single-query authorization-and-kill spine** (areas 1/3/4/6/9) — the thing CNAPP/hyperscalers structurally
do not own — with the rest honestly tiered as observe-only, roadmap, or integration-into-incumbents.

---

## Per-capability-area critique (B.1 – B.20)

#### B.1 — Agent Governance & Lifecycle *(high)*
- **Riskiest assumption:** the governance state-machine (a DB record) is authoritative over the runtime; unless every enforcement point is provably slaved to it with no bypass, "suspended" is a label, not a control.
- **Open Qs:** What forces an agent through Register→issue-identity before it can act (voluntary registration governs only the compliant subset)? Who assigns the EU-AI-Act risk class, on what evidence, and how is deliberate mis-tiering detected? What is the transition-authority model (who can flip suspended→active, is it dual-controlled)? What is the DB-state→enforcement binding latency and its fail-open/closed behaviour?
- **Kill-shot:** registration is not provably mandatory — the adversary never registers, collapsing Area 1 from a control to an inventory of the honest.
- **De-risk:** make enrolment a hard precondition of action (no SVID/OBO without an active record; admission + MCP gateway deny non-active identities); enumerate + machine-check the state-machine invariants.

#### B.2 — Agent Discovery & Inventory *(high)*
- **Riskiest assumption:** "agent" is a discoverable, stable-footprint object; in reality most 2026 agents are ephemeral/embedded/serverless/SaaS-managed with no card or workload identity.
- **Open Qs:** What is the testable definition of "an agent"? How are cardless/serverless/SaaS-managed agents discovered, and is that coverage measured? The ≥95% KPI is against a *seeded* estate — how do you prove you found the ones nobody seeded? What is the join-key/conflict model when the same agent appears as a Deployment + card + SVID + NHI + cloud record?
- **Kill-shot:** the industry trend toward embedded/serverless/SaaS agents structurally defeats footprint-based discovery — the trend that makes the problem urgent also defeats the method; CNAPP incumbents out-cover on day one.
- **De-risk:** replace the seeded KPI with a red-team discovery test (independent team plants hidden/cardless/short-lived agents); add event-driven discovery (k8s watch, cloud eventing, mesh-flow observation) and corroborate declared cards against observed traffic.

#### B.3 — Agent Identity & Card Management *(high)*
- **Riskiest assumption:** committed-vs-served card diff = tamper-evidence; but cards are unsigned JSON and the parity check (`verifyLive`) is a plaintext field diff.
- **Open Qs:** Where is a card actually signed, with what key, verified how (contracts carry no JWS/x5c/cosign)? What stops an attacker who controls the serving endpoint from serving a card that matches the committed name/skills/scopes and passes `verifyLive`? How is the card bound to the workload identity (SVID) rather than a name string?
- **Kill-shot:** an attacker who compromises the serving endpoint (the primary spoofing threat) passes the flagship tamper check because it is a plaintext diff over an unsigned card.
- **De-risk:** JWS/cosign-sign cards chained to the workload SVID; change `verifyLive` to verify the *signature*, not diff plaintext.

#### B.4 — Agentic Killswitch & Quarantine *(high)*
- **Riskiest assumption:** kill reaches proven denial across ALL paths within ≤30s; assumes five enforcement planes converge synchronously/atomically when each is eventually-consistent and TTL-bound.
- **Open Qs:** What is the revocation semantics of already-minted bearer SVIDs/OBO JWTs (valid until expiry without a denylist)? Where is kill enforced for **cloud-runtime agents** (Bedrock/Foundry/Vertex have no pod/NetworkPolicy/kyverno)? What is the residual-action window per plane?
- **Kill-shot:** bearer-token + eventual-consistency reality undercuts "≤30s proven denial"; there is no cloud-runtime enforcement primitive at all.
- **De-risk:** per-path denial matrix (mesh new-conn / existing-stream / MCP session / OBO / SVID / each cloud) with real mechanism + convergence budget; short TTLs + denylist; publish guaranteed vs worst-case denial numbers.

#### B.5 — Runtime Guardrails / LLM Guard *(high)*
- **Riskiest assumption:** a stock LLM-Guard proxy meaningfully stops prompt injection and is a defensible "control"; injection classifiers are probabilistic and routinely bypassed.
- **Open Qs:** What is the measured TP/FN against a held-out adversary-generated set (not the 5-test promptfoo baseline)? Is the guard fail-open or fail-closed on timeout/OOM (`scan_fail_fast:false`, 30s→408)? Is it in-path/mandatory or an advisory `/analyze` the broker can ignore? Multilingual/obfuscated coverage?
- **Kill-shot:** prompt injection has no robust defence — any efficacy number degrades the moment an attacker adapts; the proposal offers no fail-closed enforcement contract.
- **De-risk:** reposition as fail-closed detection-in-depth: mandatory in-path guard, explicit fail-open/closed contract, published TP/FN vs an adversarial corpus.

#### B.6 — Authorization & Policy Enforcement *(high)*
- **Riskiest assumption:** "narrow-only AuthZ-CTX" is a security control; in code it is an HS256 JWT signed with one shared secret every agent/MCP/sidecar holds.
- **Open Qs:** Where is the cryptographic binding making narrow-only adversarially safe (a compromised hop can forge a *wider* inbound context)? Orbit only checks narrowing against a caller-supplied `x-authz-action` and skips the assertion when the header is absent — what stops omission? PDP/PIP availability and fail-mode?
- **Kill-shot:** shared-secret HS256 collapses the model — a prompt-injected agent (the platform's own headline threat) forges wider authority.
- **De-risk:** asymmetric per-workload signing bound to SVIDs; each hop signs its narrowed context → verifiable delegation chain; make narrowing mandatory, not header-conditional.

#### B.7 — Collusion Detection & Access Analytics *(high)*
- **Riskiest assumption:** KubeSec-AFM is a working collusion engine covering agents; the only artefact is a dashboard page whose docstring says "all data is mock," the graph a "placeholder."
- **Open Qs:** Where is the engine, its TRL, and its IP/licensing under the King's College KTP (shippable to a bank or academically encumbered)? How does static k8s RBAC model-checking detect *agent* collusion (which happens over A2A/MCP/OBO at runtime, not Roles/RoleBindings)?
- **Kill-shot:** RBAC escalation graphing is commoditised (KubeHound, Cartography, rbac-police, every CNAPP); agent-collusion is unbuilt research, so the "working pillar" credibility claim is over-stated here.
- **De-risk:** re-scope honestly to the RBAC analyser that exists (TRL-2 mock) and flag agent-collusion as research until a real engine ingests runtime A2A/MCP capability graphs.

#### B.8 — Post-Quantum Cryptography & Crypto Agility *(high)*
- **Riskiest assumption:** a crypto-BOM/agility posture is a real capability; the implementation is hardcoded TypeScript mock constants (ciphers, root-of-trust, SVIDs, OpenBao engines) in `CryptographyPage.tsx`.
- **Open Qs:** Where does the algorithm inventory actually come from (there is no generator)? ML-KEM only covers key exchange — what is the PQC *signature* story (ML-DSA/SLH-DSA) for the trust anchors? Harvest-now-decrypt-later scope?
- **Kill-shot:** "show me the discovery" opens the file, sees hardcoded constants and no crypto-BOM generator, and concludes the capability does not exist — collapsing confidence in the other areas.
- **De-risk:** cut or demote Area 8 to a sub-bullet of Supply Chain / Observability; it is not on the MVP spine, is a mock, and excludes migration.

#### B.9 — Agent Forensics & Incident Response *(high)*
- **Riskiest assumption:** the `authz_ctx_id` trail + Witness/Archivista = a forensically complete/admissible record; but only *control-plane* events are attested, not the decisive prompt/context/output/tool-IO payloads.
- **Open Qs:** Is the LLM prompt/context/output/tool-IO itself signed and bound to `authz_ctx_id`, with what retention/PII controls? What is the trusted-timestamp/clock-integrity story for 800-86 sequencing across planes? Chain-of-custody for cloud-runtime events?
- **Kill-shot:** LLM agent forensics has a reproducibility wall — model non-determinism + provider version drift + irreversible tool side-effects make deterministic "replay"/RCA unachievable the traditional way.
- **De-risk:** define an explicit forensic evidence schema up front (which artefacts are captured, hashed, attested, retained) and attest at write-time, not after the fact.

#### B.10 — Memory & Context Management *(high)*
- **Riskiest assumption:** "agent memory" is a discrete governable object; the estate has no persistent agent-memory system (Olly agents are stateless triage agents).
- **Open Qs:** What concrete memory/RAG substrate is governed (name the store)? What is in a "context-BOM," emitted when (per call/turn/session), stored where, at what cost/volume? What is the poisoning-detection primitive and its efficacy?
- **Kill-shot:** memory/context poisoning detection is an open research problem with no benchmark — the capability risks being unfalsifiable.
- **De-risk:** pick one concrete memory/RAG substrate for the design partner, instrument inline, and prove exactly one end-to-end thread (poisoned source enters context → detected/blocked) with numbers.

#### B.11 — Supply Chain Security for Agents & Models *(high)*
- **Riskiest assumption:** OSRAMP's container-image machinery (SBOM/SLSA/cosign) transfers to models/agents unchanged; but weights, prompt-packs, RAG indices, and MCP servers are new artefact classes.
- **Open Qs:** What does a "model-BOM" actually assert (ML-BOM lists metadata, not weight integrity or training-data provenance)? How do you get SLSA L3 for a model you did not train (HuggingFace/Bedrock/Vertex/OpenAI)? Pickle/serialization exploit scanning?
- **Kill-shot:** purpose-built AI/ML supply-chain vendors (HiddenLayer, Protect AI/Guardian, Robust Intelligence, HuggingFace + Sigstore model-signing) already own model-artefact scanning and signing.
- **De-risk:** split into (a) what OSRAMP genuinely covers today (agent/MCP-server images, SBOM, SLSA for artefacts you build, cosign at admission) and (b) model-artefact assurance via integration with the AI-ML supply-chain incumbents.

#### B.12 — Observability & Estate Pane-of-Glass *(high)*
- **Riskiest assumption:** a read-only pane is a low-risk enhancement; in fact it is the primary trust surface, it drives the kill action, and it renders attacker-controlled agent data.
- **Open Qs:** What is the freshness/staleness-detection SLA (a lagged "live" view during an incident is dangerous)? How does the pane represent what it *cannot* see (inherits Area-2 blind spots)? Output-encoding of untrusted agent text in the console?
- **Kill-shot:** hyperscaler/CNAPP incumbents already own the telemetry substrate (Splunk/Jarvis is literally Splunk here) and estate graph.
- **De-risk:** move the security-critical slice into the MVP with a first-class threat model (STRIDE + OWASP-LLM for "attacker-controlled data rendered in operator console"); CI regression that seeds hostile agent text.

#### B.13 — Human-in-the-Loop Approvals & Action Gating *(high)*
- **Riskiest assumption:** an ed25519-signed `approval_jwt` = genuine human authorization; the control collapses to one broker key + a self-asserted, free-text `approved_by` (`approval.py:198`).
- **Open Qs:** Where does the broker signing key live and what stops a compromised broker minting arbitrary approvals? Is the human approver's Dex/OIDC session cryptographically bound into the token, or is `approved_by` free text? Replay/one-time-use of the approval?
- **Kill-shot:** standards churn — the gate is welded to ADK `require_confirmation`→A2A `input-required`, and the code admits the ADK-native path is not the enforced one.
- **De-risk:** bind approval to a fresh authenticated human at signing (Dex/OIDC, ideally WebAuthn step-up) with verified `sub`/session/auth-time in the JWT; one-time-use, scoped to the exact action hash.

#### B.14 — Compliance & Regulatory Mapping *(high)*
- **Riskiest assumption:** self-generated, self-attested, self-mapped evidence will be accepted by a sceptical auditor as authoritative.
- **Open Qs:** Who authors and legally warrants the framework mappings (EU AI Act/DORA/NIS2 differ per member state and are still finalising)? What exact articles/controls does an "evidence pack" satisfy (Art 9/12/14/15; DORA ICT-risk; NIS2 Art 21)? Where is the accredited-assessor validation?
- **Kill-shot:** GRC incumbents (Vanta, Drata, OneTrust, ServiceNow GRC, IBM OpenPages, Archer) already own framework-mapping + audit-accepted evidence with assessor relationships.
- **De-risk:** reframe from "compliance engine" to "attested agent-evidence feed" that exports into the customer's existing GRC system of record rather than owning framework interpretation.

#### B.15 — Adversarial Testing & Continuous Evaluation *(high)*
- **Riskiest assumption:** passing a promptfoo/`eval-record` CI gate implies the agent is safe; adversarial ML is non-stationary and the corpus is known to the defender.
- **Open Qs:** What is the pass/fail threshold and the waiver path when a model update regresses the baseline? Where does the corpus come from, how often refreshed, and how is OWASP-LLM/ATLAS *coverage* demonstrated (not name-dropped)?
- **Kill-shot:** "you passed your own test but the attacker didn't take your test" — no eval proves an LLM agent injection-proof.
- **De-risk:** define the eval as a measurable coverage contract (OWASP-LLM-Top-10 × MITRE-ATLAS matrix with per-cell status + published coverage % + explicit "not covered" list).

#### B.16 — Multi-Cloud / Multi-Orchestrator Coverage *(high)*
- **Riskiest assumption:** managed cloud runtimes (Foundry/Bedrock/Vertex) can be "normalised into the common identity + card + policy model"; they expose no A2A card, no SPIFFE SVID, and no enforceable kill surface.
- **Open Qs:** For a cardless/SVID-less cloud agent, what IS the identity and how does the killswitch deny action? The MVP scopes "read-only discovery, no runtime changes" — so cloud agents are discover-only, not kill/guard/identity-bound: is that stated to the buyer?
- **Kill-shot:** this is exactly where hyperscalers/CNAPP win by default — they already govern/log/disable their own runtimes natively.
- **De-risk:** publish a per-runtime × per-control matrix (enforce / observe-only / not-possible) to force honesty about coverage.

#### B.17 — Tenant Isolation & Multi-Tenancy *(high)*
- **Riskiest assumption:** "per-tenant binding + RLS-equivalent + per-tenant SPIFFE domains + default-deny" all hold simultaneously across a *shared* control plane, guardrails, MCP gateway, and inference paths — soft multi-tenancy sold as isolation.
- **Open Qs:** Is this soft (shared DB + row filtering) or hard (per-tenant namespace/cluster/DB) isolation — a bank will reject a shared Postgres with app-layer filtering for regulated data? Is "RLS-equivalent" engine-enforced Postgres RLS or a `WHERE tenant_id=?` any missing clause breaks? What about the *non-DB* paths (shared vector store, shared LLM-guard cache, cross-tenant prompt-injection)?
- **Kill-shot:** a curious Tenant-A operator demonstrates cross-tenant disclosure via a non-database path the "RLS-equivalent" never covered — the existing threat model already notes the schema has *no tenant column* (TM-01).
- **De-risk:** commit to an explicit isolation tier and defend it — for a bank, default to hard isolation (per-tenant namespace/cluster or dedicated schema, engine-enforced RLS as a floor, no shared inference/guard/memory across tenants) with cross-tenant denial proofs.

#### B.18 — Behavioral Analytics & Anomaly Detection *(high)*
- **Riskiest assumption:** per-agent behavioural baselines are learnable/stable/separable from malice; non-deterministic, task-dependent, frequently-updated agents make "normal" hard to define.
- **Open Qs:** What is the concrete detection algorithm (rules / statistical / ML / LLM-judge — each with different FPR)? Cold-start for new/rare/open-ended agents? Precision/recall/FPR/MTTD targets and eval harness?
- **Kill-shot:** detection efficacy is unfalsifiable as written — no algorithm, dataset, metrics, or harness.
- **De-risk:** reclassify out of any auto-kill path for the MVP (detect-and-alert, human-in-loop, no auto-quarantine authority until efficacy is proven); route signals to the console, not the killswitch.

#### B.19 — Federated Trust & Cross-Zone Identity *(high)*
- **Riskiest assumption:** SPIFFE Federation (built to *establish* trust) can be inverted into fast, reliable *revocation* ("governed, revocable trust"); SPIFFE has no native revocation channel.
- **Open Qs:** What is the actual cross-zone revocation latency (no CRL/OCSP; = SVID TTL + bundle-refresh + xDS push)? Who is the authoritative federation policy authority, and what stops a compromised peer SPIRE server minting SVIDs Zone A implicitly trusts?
- **Kill-shot:** direct contradiction — the ≤30s killswitch (Area 4) vs SPIFFE-federation identity (Area 19): federated peers honour a revoked SVID until TTL, so cross-zone kill cannot meet the SLA.
- **De-risk:** add out-of-band, cryptographically-pinned signed trust-bundle distribution + break-glass bundle rotation with dual control; add "federated trust-bundle poisoning" to the threat model.

#### B.20 — Reporting, Alerting & SOC/SIEM Integration *(high)*
- **Riskiest assumption:** existing SIEM/SOAR will natively consume/trust/act on "signed event feeds"; OCSF/CEF has no native agent-domain event classes.
- **Open Qs:** Are you inventing OCSF extensions/profiles for A2A hop / MCP denial / kill / `authz_ctx_id` lineage / attestation — who governs/versions the schema? What exactly is "signed" (per-event / Merkle-root / TLS-relabelled), and what does the SIEM do with the signature?
- **Kill-shot:** the "attested forensic trail" KPI collapses the moment the record of record leaves the platform into the customer's *mutable* Splunk/ServiceNow.
- **De-risk:** publish an explicit event-schema contract (OCSF extension/profile per agent-domain event class) and keep an immutable platform-side attested store the customer cannot mutate, with the SIEM as a downstream copy.

---

## Strategic-lens critique

#### Commercial / GTM
- **Findings:** no named buyer with budget, no price, no packaging, no ACV (Finances = three "TBD" lines); regulatory pain asserted but never converted to £ fine exposure / audit-hours saved / breach-cost avoided.
- **Kill-shot:** "show me the money" — non-fundable as a commercial proposal; an approver cannot say yes to revenue with no customer, contract shape, or figure.
- **Recommendation:** secure a signed design-partner LOI / paid pilot from the ARC client with a price, success criteria, and a 90-day first-value milestone *before* build approval.

#### Competitive Landscape
- **Findings:** "first agent security control plane" is falsifiable — Wiz (AI-SPM), Palo (Prisma AIRS + Protect AI), CrowdStrike, and hyperscaler-native guardrails already cover much of this; breadth (20 areas) is surface area competitors erode one feature at a time, not a moat.
- **Kill-shot:** one-line CISO demolition — "Wiz/Palo already discover my agents and Bedrock guardrails are on by default; why buy a startup's orchestration over open-source parts my team could wire in a sprint?"
- **Recommendation:** reframe to a narrow, defensible wedge incumbents structurally cannot own — the cryptographically-attested, single-query "who authorized this agent action?" + kill, with evidence independent of the customer's mutable estate.

#### Technical Feasibility
- **Findings:** the killswitch (the flagship) is the weakest claim — distributed multi-plane revocation with no consistency guarantee; "four working local demos" ≠ "composes into one attested chain end-to-end."
- **Kill-shot:** a fast, reliable killswitch is unachievable as specified for the general case (revoking live connections + cached credentials across five eventually-consistent planes; no cloud-runtime primitive).
- **Recommendation:** re-scope the killswitch to what is physically enforceable and measure it honestly — per-plane convergence budgets + a two-number "denial guarantee" (guaranteed vs worst-case-residual).

#### Regulatory Defensibility
- **Findings:** "Regulatory Immunity" is legally indefensible (EU AI Act Art 16/26, DORA Art 5 impose non-transferable obligations); the "mock auditor pass" KPI is self-graded and unfalsifiable.
- **Kill-shot:** a CISO who buys "immunity" and then faces an enforcement action has been mis-sold — the core value proposition is legally false.
- **Recommendation:** kill the term everywhere; reframe as auditable evidence generation + continuous control-monitoring that *reduces the cost and time* of demonstrating EU AI Act / DORA compliance; obtain real accredited-assessor validation.

#### Red-Team-The-Platform *(synthesised from cross-area findings)*
- **Findings:** the control plane is the highest-value target — poison the inventory (register a rogue agent as active/minimal-risk/tenant-A), forge a card that passes the plaintext `verifyLive`, forge a wider AuthZ-CTX with the shared HS256 secret, mint a self-asserted HITL approval, or tamper the forensic trail once it lands in mutable Splunk.
- **Kill-shot:** a single compromised or prompt-injected agent + control-plane token can flip a suspended agent back to active, defeating the killswitch the whole spine underpins.
- **Recommendation:** apply the platform's own strongest controls to itself — signed state transitions attested at write-time, asymmetric per-workload signing, quorum/dual-control on classification and un-suspend, an immutable evidence store, and a documented break-glass with dual control; purple-team the control plane as a first-class target.
