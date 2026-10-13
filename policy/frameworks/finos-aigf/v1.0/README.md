# FINOS AI Governance Framework (AIGF) pack, v1.0

This pack contains CEL checks. Each check evaluates one fact about an AI agent.
That fact is evidence for one mitigation in the FINOS AIGF catalogue.

- Control IDs are the catalogue's own mitigation IDs, `AIR-PREV-nnn` and
  `AIR-DET-nnn`. The pack invents no IDs.
- The control sets follow the catalogue's split into preventative (`PREV`) and
  detective (`DET`) mitigations.
- Each control's description lists the catalogue risks that the mitigation
  addresses.

## Files

- `framework.json`: the pack. The policy engine loads this file.
- `AGENT-CONTEXT.md`: the schema of the `agent` document. It covers every
  field path, its type, and what happens when the field is absent.
- `fixtures/unit/`: one-fact-changed pass and fail cases, and edge cases.
- `fixtures/integration/`: four realistic agents, each with the complete
  verdict vector.

Run the harness:

```bash
cd d2-signalloom/apps/policy-engine && go test -run 'TestConformance_(Verdicts|Coverage|FixturesWellFormed)' -count=1 -v .
```

## Source of truth

| | |
|---|---|
| Repository | <https://github.com/finos/ai-governance-framework> |
| Commit | `a149dd1eb763c0be4ff8107b698c41230ecfbfc8`, committed 2026-10-07 |
| Catalogue version | `v2` (`ai-governance-framework/docs/_config.yml`) |
| Mitigations | `docs/_mitigations/mi-N_*.md`, published at <https://air-governance-framework.finos.org/> |
| ID rule | `AIR-{type}-{sequence, zero-padded to 3}` (`ai-governance-framework/docs/_includes/mitigation-id.html`, `risk-id.html`) |

Every mitigation used here is at `doc-status: Approved-Specification`, except
`AIR-PREV-024`. At the pinned commit that mitigation is `Draft`, and its
control description says so.

## Mapping

| Check | Mitigation | Title | Field paths |
|---|---|---|---|
| `rag-ingestion-sensitive-data-filtered` | AIR-PREV-002 | Data Filtering From External Knowledge Bases | `data.rag_enabled`, `data.ingestion_sensitive_data_filter` |
| `prompt-injection-guardrail-active` | AIR-PREV-003 | User/App/Model Firewalling/Filtering | `guardrails.prompt_injection_filter` |
| `output-leakage-filter-active` | AIR-PREV-003 | User/App/Model Firewalling/Filtering | `guardrails.output_filter` |
| `inference-rate-limit-configured` | AIR-PREV-008 | Quality of Service (QoS) and DDoS Prevention for AI Systems | `rate_limits.requests_per_minute` |
| `registered-model-registry-entry` | AIR-PREV-010 | AI Model Version Pinning | `registry.model_registered` |
| `model-version-pinned` | AIR-PREV-010 | AI Model Version Pinning | `registry.model_version` |
| `user-authn-and-rbac-enforced` | AIR-PREV-012 | Role-Based Access Control for AI Data | `access.authentication_required`, `access.rbac_enforced` |
| `ai-data-encrypted-at-rest` | AIR-PREV-014 | Encryption of AI Data at Rest | `data.persistent_stores[].encrypted_at_rest` |
| `tool-grants-least-privilege` | AIR-PREV-018 | Agent Authority Least Privilege Framework | `tools[].scopes` |
| `mcp-servers-allowlisted` | AIR-PREV-020 | MCP Server Security Governance | `mcp_servers[].allowlisted` |
| `no-long-lived-credentials-exposed` | AIR-PREV-023 | Agentic System Credential Protection Framework | `credentials.long_lived_secrets_exposed` |
| `high-impact-actions-human-approved` | AIR-PREV-024 | Human-in-the-Loop Action Approval Gate (Draft) | `tools[].impact`, `tools[].requires_human_approval` |
| `ai-interaction-audit-logging` | AIR-DET-004 | AI System Observability | `observability.audit_logging` |
| `spend-budget-alerting-configured` | AIR-DET-009 | AI System Alerting and Denial of Wallet (DoW) / Spend Monitoring | `cost_controls.budget_limit`, `cost_controls.spend_alerting` |
| `decision-explainability-metadata` | AIR-DET-021 | Agent Decision Audit and Explainability | `governance.decision_explainability` |
| `decision-audit-tamper-evident` | AIR-DET-021 | Agent Decision Audit and Explainability | `governance.audit_log_tamper_evident` |

### Where the three original checks now sit

The three original checks keep their IDs and field paths.

- `registered-model-registry-entry` sits under AIR-PREV-010. That
  mitigation's guidance includes "Keep an up-to-date inventory of all deployed
  AI models, their specific pinned versions, and their business owners". The
  catalogue has no separate model-registry mitigation. It was re-checked against
  all 25 mitigations at a149dd1e after the cross-vendor audit questioned the fit
  (pinning is not registration). AIR-PREV-010 is the only one whose text
  covers a model inventory. This appears in its "Maintain an Inventory and Conduct
  Regular Audits" action and its NIST `cm-8` System Component Inventory reference.
  AIR-PREV-012's "Data Asset Inventory" covers data assets, not deployed
  models. The check stays under AIR-PREV-010.
- `prompt-injection-guardrail-active` sits under AIR-PREV-003. Its "User Input
  to the AI Model" control names prompt injection directly.
- `decision-explainability-metadata` sits under AIR-DET-021.

Each of the three now also guards its leaf with `has()`. The meaning is
unchanged. When the key is absent the check now fails, whereas before it raised
an error.

## Mitigations not mapped

Agent configuration and registry facts cannot evidence these mitigations.
They are left out on purpose, and this pack does not approximate them.

| Mitigation | Why it is not a configuration fact |
|---|---|
| AIR-DET-001 AI Data Leakage Prevention and Detection | Needs runtime detection telemetry. AIR-PREV-003 output filtering covers the configuration side. |
| AIR-PREV-005 System Acceptance Testing | Evidence is a test record, not an agent attribute. |
| AIR-PREV-006 Data Quality & Classification/Sensitivity | Evidence is a data-governance record. |
| AIR-PREV-007 Legal and Contractual Frameworks for AI Systems | Evidence is a contract. |
| AIR-DET-011 Human Feedback Loop for AI Systems | Evidence is a process, not configuration. |
| AIR-DET-013 Providing Citations and Source Traceability | Could be added later as a RAG-conditional check, if the registry records citation output. |
| AIR-DET-015 LLM-as-a-Judge | Evidence is an evaluation pipeline. |
| AIR-DET-016 Preserving Source Data Access Controls | Could be added later as a RAG-conditional check. |
| AIR-PREV-017 AI Firewall Implementation and Management | Overlaps AIR-PREV-003 at configuration level. |
| AIR-PREV-019 Tool Chain Validation and Sanitization | Needs runtime parameter validation evidence. |
| AIR-PREV-022 Multi-Agent Isolation and Segmentation | Belongs to the `request.peer` runtime context, not to the agent document. |
| AIR-PREV-025 Skill/Plugin Integrity and Governance | Draft at the pinned commit. Needs signed skill provenance. |

## Severity and FAIR triples

The three original checks keep their triples. The triples for the new checks
are calibrated by severity against the original three. They are not market
data.

## Pricing coverage

The table below is produced from `framework.json`. It is not typed by hand.
`make policy-pricing-counts` fails if it drifts from the packs.

A check is priced when its `freqTriple` has a non-zero `min`, `mode`, or `max`.
A check with no frequency triple, or an all-zero one, is unpriced. An unpriced
check contributes GBP 0.00 to every reported total however often it fails. That
state is allowed, because a loss magnitude with no calibrated frequency is not a
price. It is not a small-print detail, because a reader who adds up a scan gets
a total over the priced checks only.

### What these figures are a share of

A `riskTriple` mode here is the **attributable share of one loss event assigned
to one failed control**. It is not the cost of the loss event. Published
single-event loss medians sit one to two orders of magnitude above these modes
(IRIS 2022, <https://www.cyentia.com/iris-2022/>). The event-level figures are
the `SCN-*` magnitudes in [`risk/org/acme.yaml`](../../../../risk/org/acme.yaml).

Every priced check carries a derivation entry in `CALIBRATION.md` beside this
pack. It names the anchor classes behind both triples, the scenario the check
is a share of, and a confidence letter. The registry is
[ANCHORS.md](../../ANCHORS.md). Statutory ceilings are a `max` and never a
`mode`, and they are in [PENALTIES.md](../../PENALTIES.md).

This pack's AI-guardrail frequencies are the weakest in the estate.
`AC-AI-LOSS` is an empty anchor class. **No public or commercial dataset
prices prompt injection, model exfiltration or unauthorised agent action.**
Those frequencies are judgement at confidence D and the derivation says so.

Three checks in this pack were moved off the technical loss path on
2026-10-11. `registered-model-registry-entry`, `model-version-pinned` and
`decision-explainability-metadata` defend against a penalty rather than a
breach. They are declared in `catalogue/unpriced.tsv` with the reason code
`penalty-path-not-technical`.

Read [the calibration statement](../../README.md#the-calibration-statement) before you quote
any figure in this table or any figure the engine produces from this pack.

<!-- pricing-counts:begin -->
| Version | Checks | Priced | Unpriced | Placeholder |
| :--- | ---: | ---: | ---: | ---: |
| `v1.0.0` | 16 | 13 | 3 | 0 |
| **Pack total** | **16** | **13** | **3** | **0** |

An unpriced check contributes GBP 0.00 to every total however often it
fails. Of 16 check(s) on this page, 13 are priced and 3 are not.
Written by `policy/frameworks/pricing-counts-test.sh`. Do not edit by hand.
<!-- pricing-counts:end -->
