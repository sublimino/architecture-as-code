# FINOS AIGF pack: agent context document

The CEL variable `agent` holds this document. fe-signalloom assembles it from the
agent registry. Every check in `framework.json` reads only the paths below.
The contract is in [`../../CONFORMANCE.md`](../../CONFORMANCE.md).

## Rules that apply to every field

- **Booleans.** Only the JSON boolean `true` counts as evidence. The string
  `"true"`, the number `1` and an absent key all fail. The one negative-sense
  leaf, `credentials.long_lived_secrets_exposed`, passes only on the JSON
  boolean `false`.
- **Numbers** are JSON numbers. They arrive as float64. A numeric string such
  as `"120"` fails.
- **Absent means unevidenced, so the check fails.** No check returns `error`
  for an absent key. A missing container object fails too.
- **Container objects** (`registry`, `guardrails`, `data`, and the rest) must
  be JSON objects. A container of the wrong type, such as a string or a list, makes its
  checks fail (every container read is guarded with `type(x) == map`; list
  elements of `persistent_stores`, `tools` and `mcp_servers` likewise).
- **Lists** must be JSON arrays.
  - An empty array `[]` declares "none", so every-element checks pass on it
    (vacuous truth).
  - An absent field does not declare "none", so it fails.
  - An object in place of the list fails, even an empty object `{}`.
- **Applicability must be declared.** A conditional check is not applicable
  only when the producer says so explicitly (`rag_enabled: false`, or no tool
  classified high impact). If the applicability fact is unknown or has the
  wrong type, the check fails.
- The checks ignore extra fields, such as `id`, `name`, `owner` and
  `knowledge_bases`.

## Fields

| Path | Type | Meaning | Absent / wrong type | Read by |
|---|---|---|---|---|
| `registry.model_registered` | bool | The model is in the enterprise model inventory and is approved. | fail | `registered-model-registry-entry` (frozen) |
| `registry.model_version` | string | The exact model version deployed. It must contain at least one character and no whitespace. It must not end in a `latest` alias segment. The match is case-insensitive: `x-latest`, `x:latest`, `x@latest`, `x/latest`, `x.latest`, `x_latest` and bare `latest` all fail. A version that only contains `latest` elsewhere passes. | fail | `model-version-pinned` |
| `guardrails.prompt_injection_filter` | bool | Prompt-injection detection runs on input. | fail | `prompt-injection-guardrail-active` (frozen) |
| `guardrails.output_filter` | bool | Model output is filtered for leakage and policy violations before release. | fail | `output-leakage-filter-active` |
| `data.rag_enabled` | bool | The agent retrieves from knowledge bases (RAG). This is the applicability fact. | fail (unknown applicability) | `rag-ingestion-sensitive-data-filtered` |
| `data.ingestion_sensitive_data_filter` | bool | Sensitive data is filtered or redacted before ingestion into RAG. Required only when `rag_enabled` is `true`. | fail if RAG is enabled; ignored otherwise | `rag-ingestion-sensitive-data-filtered` |
| `data.persistent_stores` | array of objects | Every store the agent persists to: vector indexes, conversation history, caches. `[]` means the agent persists nothing. | fail | `ai-data-encrypted-at-rest` |
| `data.persistent_stores[].encrypted_at_rest` | bool | The store is encrypted at rest. | fail for that store | `ai-data-encrypted-at-rest` |
| `rate_limits.requests_per_minute` | number | The enforced request rate limit. It must be greater than 0. Fractions are allowed. | fail | `inference-rate-limit-configured` |
| `access.authentication_required` | bool | Callers must authenticate. | fail | `user-authn-and-rbac-enforced` |
| `access.rbac_enforced` | bool | Role-based authorisation is enforced on the agent's data and actions. | fail | `user-authn-and-rbac-enforced` |
| `tools` | array of objects | The tools the agent can invoke. `[]` means no tools. | both tool checks fail | `tool-grants-least-privilege`, `high-impact-actions-human-approved` |
| `tools[].scopes` | array of strings | The scopes granted to the tool. The array must not be empty. Every entry must be a non-empty string and must not end in `*`, so neither `*` nor `repo:*` is allowed. | fail | `tool-grants-least-privilege` |
| `tools[].impact` | `"low"` \| `"medium"` \| `"high"` | The impact class. Absent, or any other value, is treated as `high` (fail-closed). | treated as high | `high-impact-actions-human-approved` |
| `tools[].requires_human_approval` | bool | Calls to this tool wait at a human approval gate. Required when the impact is high or unclassified. | fail if the tool is high or unclassified | `high-impact-actions-human-approved` |
| `mcp_servers` | array of objects | The MCP servers the agent connects to. `[]` means none. | fail | `mcp-servers-allowlisted` |
| `mcp_servers[].allowlisted` | bool | The server is on the central, security-vetted allow-list. | fail | `mcp-servers-allowlisted` |
| `credentials.long_lived_secrets_exposed` | bool | `true` if static or long-lived secrets are present in the agent's environment, files or context. `false` is the evidence that they are absent. | fail | `no-long-lived-credentials-exposed` |
| `observability.audit_logging` | bool | Prompts, responses, tool calls and policy decisions are written to the audit log. | fail | `ai-interaction-audit-logging` |
| `cost_controls.budget_limit` | number | The spend budget for the agent's model usage. It must be greater than 0. The pack does not fix a currency or period. | fail | `spend-budget-alerting-configured` |
| `cost_controls.spend_alerting` | bool | Alerts fire against that budget. | fail | `spend-budget-alerting-configured` |
| `governance.decision_explainability` | bool | Reasoning traces and explainability metadata are recorded. | fail | `decision-explainability-metadata` (frozen) |
| `governance.audit_log_tamper_evident` | bool | The decision log is integrity-protected: append-only, hash-chained or signed. | fail | `decision-audit-tamper-evident` |

The three frozen paths are `registry.model_registered`,
`guardrails.prompt_injection_filter` and `governance.decision_explainability`.
These paths and their meaning ship unchanged. Extend this document; never
rename a field in it.

## Minimal compliant document

```json
{
  "registry": { "model_registered": true, "model_version": "claude-sonnet-4-5-20250929" },
  "guardrails": { "prompt_injection_filter": true, "output_filter": true },
  "data": { "rag_enabled": false, "persistent_stores": [] },
  "rate_limits": { "requests_per_minute": 120 },
  "access": { "authentication_required": true, "rbac_enforced": true },
  "tools": [],
  "mcp_servers": [],
  "credentials": { "long_lived_secrets_exposed": false },
  "observability": { "audit_logging": true },
  "cost_controls": { "budget_limit": 5000, "spend_alerting": true },
  "governance": { "decision_explainability": true, "audit_log_tamper_evident": true }
}
```
