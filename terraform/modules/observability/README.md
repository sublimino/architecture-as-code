# `modules/observability`

Audit sink, data-access audit config, uptime checks, alert policies, and the billing budget for
the Signal Loom GCP demo platform.

Instantiated **once**, by `terraform/platform`. It is deliberately not per-environment: an audit
trail that `make gcp-tf-destroy ENV=demo-1` can delete is not an audit trail, and a budget scoped
to one demo cannot tell you the estate is overspending. Because these resources live in the
platform root's state and the environments root never references them, the separation is
structural rather than a convention someone has to remember.

## What it creates

| Resource | Why |
|---|---|
| `google_storage_bucket.audit_logs` | Dedicated audit destination. Versioned, uniform bucket-level access, public access prevention enforced, `force_destroy = false`. |
| `google_logging_project_sink.admin_activity` | Routes Admin Activity, System Event, Policy Denied and Data Access logs to that bucket, with a unique writer identity. |
| `google_storage_bucket_iam_member.sink_writer` | Grants the sink writer `roles/storage.objectCreator` on the audit bucket only — it can add evidence, never remove it. |
| `google_project_iam_audit_config.data_access` | Turns on DATA_READ/DATA_WRITE audit logging, which GCP leaves off by default for everything but IAM. |
| `google_monitoring_uptime_check_config.demo` | One HTTPS uptime check per entry in `uptime_targets`, with `validate_ssl = true`. |
| `google_monitoring_alert_policy.uptime_failure` | One policy per uptime target, pinned to that check's id. |
| `google_monitoring_alert_policy.backend_unhealthy` | 5xx rate on the LB's own request counter — see the note below. |
| `google_billing_budget.platform` | Thresholds at 50%, 80% and 100%, gated behind `billing_account_id`. |

## Inputs

The first eight are the frozen interface from `terraform/CONTRACT.md` §4. The remaining five are
additive and **all defaulted**, so a caller passing exactly the contract's eight inputs still
plans.

| Name | Type | Default | Notes |
|---|---|---|---|
| `project_id` | string | — | Validated against the GCP project-id grammar. |
| `labels` | map(string) | — | Mandatory label set, applied to every labellable resource. |
| `log_retention_days` | number | — | 30–3650. Drives both the retention policy and the lifecycle rule. |
| `uptime_targets` | map(object({hostname, app_port})) | `{}` | Keyed by environment key. |
| `notification_channel_ids` | list(string) | `[]` | Must be non-empty when `enable_alerts` is true. |
| `billing_account_id` | string | `""` | `""` disables the budget. |
| `budget_amount_currency` | string | `"GBP"` | ISO 4217. |
| `budget_amount_units` | number | `500` | Whole currency units. |
| `name_prefix` | string | `"sl-platform"` | Additive. Platform-scoped, not environment-scoped. |
| `log_bucket_location` | string | `"europe-west2"` | Additive. |
| `state_bucket_name` | string | `""` | Additive. Supplied so the module can *prove* its bucket differs from the state bucket. |
| `enable_alerts` | bool | `true` | Additive. `false` omits the policies; it never creates channel-less ones. |
| `data_access_services` | list(string) | 5 services | Additive. |

## Outputs

`log_bucket_name` and `log_sink_writer_identity` are the contract outputs. `log_bucket_self_link`,
`uptime_check_ids`, `alert_policy_names` and `budget_enabled` are additive.

## Two decisions worth knowing about

**The empty-channel validation is a hard failure, not a default.** `notification_channel_ids`
carries a cross-variable validation block (Terraform ≥ 1.9) that rejects an empty list while
`enable_alerts` is true. An alert policy with no notification channel is accepted happily by both
Terraform and GCP: it fires, it is recorded in the console, and the first human to learn of the
outage is whoever tried to use the demo. There is nowhere else in the stack that this mistake
surfaces, so it is caught here or not at all. The block does not fall back to a default channel —
a guard that repairs what it detects can never fail, and the broken input ships green.

**The backend-health alert is a 5xx-rate proxy, and is labelled as one.** GCP does not export a
"backend healthy" gauge for the classic external HTTPS load balancer. When the backend instance
group has no healthy member the LB serves 502s, so
`loadbalancing.googleapis.com/https/request_count` filtered to `response_code_class="500"` is the
honest signal. It is documented as a proxy rather than presented as a direct health check,
because someone will eventually debug an alert that did not fire and needs to know what it was
actually watching.

## Tests

`tests/observability.tftest.hcl` — 9 `run` blocks, `mock_provider` throughout, `command = plan`
only, ~0.6 s. These assert on the **evaluated** configuration, not on the HCL text: that the sink's
resolved `destination` is not the state bucket, that the retention period equals
`log_retention_days * 86400` rather than a literal, that the budget's threshold list evaluates to
exactly `[0.5, 0.8, 1.0]`, and that every alert policy the plan produced carries at least one
notification channel.

The negative run (`expect_failures` on an empty channel list with alerts enabled) is paired with
**two** positives: one proving the corrected input plans, and one proving `enable_alerts = false`
is the sanctioned way to have no channels. Without the pair, "reject empty channels" would be
indistinguishable from "channels are always mandatory", and a run block failing for an unrelated
reason would be indistinguishable from the validation firing correctly.

Both assertions have been mutation-checked: pointing the audit bucket at the state bucket, and
changing one budget threshold from `0.8` to `0.9`, each turn the suite red.

## Verify

```sh
terraform -chdir=terraform/modules/observability init -backend=false
terraform -chdir=terraform/modules/observability validate
terraform -chdir=terraform/modules/observability test
tflint --chdir=terraform/modules/observability
```

Or, for the whole tree plus the bats contract suites, `make gcp-tf-validate`. Discovery is
automatic — this module's `tests/` directory is swept because it exists, not because it is named
in a list anywhere.
