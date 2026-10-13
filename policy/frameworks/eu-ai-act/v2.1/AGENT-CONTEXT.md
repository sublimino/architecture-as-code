# eu-ai-act v2.1 — agent and request context

Paths this pack reads from `agent` and `request`. Shipped paths are frozen:
extend, never rename. Every path is `has()`-guarded, so an absent path fails
the check (or passes, where stated) instead of erroring.

## `agent`

| Path | Type | Check | Absent means |
|------|------|-------|--------------|
| `agent.training_data_provenance.validated` | bool | `training-data-provenance` | fail |
| `agent.technical_documentation.annex_iv_compliant` | bool | `annex-iv-technical-documentation` | fail |
| `agent.logging_config.automatic_record_keeping` | bool | `automatic-record-keeping` | fail |
| `agent.transparency.user_instructions_available` | bool | `user-instructions-transparency` | fail |
| `agent.deployer_oversight.continuous_monitoring` | bool | `deployer-monitoring-active` | fail |
| `agent.model_type` | string | `synthetic-content-marking` | pass: marking applies only when `model_type == 'generative'` |
| `agent.transparency.synthetic_content_watermarking` | bool | `synthetic-content-marking` | fail, when the model is generative |

Only the boolean `true` passes a bool path. The string `"true"` fails.

## `request`

| Path | Type | Check | Absent means |
|------|------|-------|--------------|
| `request.tool_call.action` | string | `block-unauthorized-host-exec` | pass: only `exec`, `write_file` and `modify_iam` are gated |
| `request.context.claims[]` | list of `{type, valid}` | `block-unauthorized-host-exec` | fail, for a gated action |

A gated action passes only with a claim where `type == 'human_approval_svid'`
and `valid == true`.

`synthetic-content-marking` and `block-unauthorized-host-exec` pass when their
trigger is absent. That keeps the behaviour the pack shipped with, and the
`bare-pod` fixtures pin it.
