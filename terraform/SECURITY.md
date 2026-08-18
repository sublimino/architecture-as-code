# Security — threats, and the named thing that mitigates each

Every row maps a threat from the proposal's Security and Risk table to the
**specific Terraform resource or Make guard** that implements the mitigation. A
mitigation with no name is an intention.

> **The IP allowlist is exposure control, not authentication.** It reduces who
> can reach the demo. It says nothing about who they are, it is trivially
> defeated by anyone on an allowlisted network, and a demo behind an allowlist
> is not a demo behind a login. Treat every demo environment as reachable by
> everyone on the allowlisted ranges, and put nothing in it you would not put in
> a public repository.

---

## 1. State bucket exposure or deletion

**Threat.** Terraform state holds resource identifiers, IAM member lists, and
anything a provider marks sensitive. A public or deletable state bucket exposes
the shape of the estate, and losing it orphans every resource in it.

| Mechanism | Where |
|---|---|
| `public_access_prevention = "enforced"` | `terraform/bootstrap` state bucket, asserted by a `.tftest.hcl` on the *evaluated* attribute (ISC-339) |
| `uniform_bucket_level_access = true` | same — removes per-object ACLs as an exposure path |
| `versioning { enabled = true }` | same (ISC-341); a bad apply is recoverable |
| `force_destroy = false` + `lifecycle { prevent_destroy = true }` | same (ISC-340) |
| **No plan/apply principal holds `roles/storage.admin` on the state bucket** | `modules/identity` — `roles/storage.objectAdmin` is sufficient to read and write state objects and insufficient to delete the bucket |
| The destroy target's argument list cannot name the bucket | `test/terraform-make-contract.bats` → "the destroy argument list cannot reach the state bucket", asserted against the recorded `terraform destroy` argv |
| `gcp-tf-destroy` refuses the `bootstrap` root | Makefile `gcp-tf-destroy`, tested by execution |

**The honest part.** `prevent_destroy` and `force_destroy = false` live *in the
config* — the same commit that destroys the bucket can delete them. They are
tripwires, not enforcement. The only real mechanism is the IAM row: a principal
without `storage.admin` cannot delete the bucket regardless of what the config
says. Assert the negative as well as the positive (CONTRACT §5c).

## 2. Over-broad CI identity

**Threat.** A CI identity that can do anything can be made to do anything by
anyone who can open a pull request.

| Mechanism | Where |
|---|---|
| Workload Identity Federation — **no service account keys anywhere** | `modules/identity`; `google_service_account_key` is a prohibited resource (CONTRACT §6) and absence is asserted whole-tree in bats |
| WIF `attribute_condition` pinned to owner **numeric id**, repository, and a single ref | `modules/identity`, asserted non-empty by `.tftest.hcl` (ISC-350) |
| Split plan/apply identities — plan is read-only | `modules/identity` outputs `ci_plan_service_account_email` / `ci_apply_service_account_email` |
| No `roles/owner` or `roles/editor` binding anywhere | CONTRACT §6, asserted whole-tree in bats |
| No `google_project_iam_policy` (authoritative; would destroy existing bindings) | CONTRACT §6; `google_project_iam_member` only |
| The PR-time gate holds **no** credentials at all | `.github/workflows/terraform-validate.yaml` — no auth step, plus an explicit step that fails if any credential env var or ADC file is present |
| Every offline terraform invocation runs with credentials stripped | Makefile `GCP_TF_NOCREDS`, tested (ISC-357) |

A numeric owner id rather than a login, because a GitHub login can be released
and re-registered by a stranger. The numeric id cannot.

## 3. Direct VM exposure

**Threat.** A demo VM with a public IP is an internet-facing host whose only
protection is whatever is listening on it.

| Mechanism | Where |
|---|---|
| No `access_config` block anywhere — the VM has no external IP | `modules/compute`; prohibited construct, absence asserted whole-tree in bats (CONTRACT §6) |
| Ingress reaches the VM only via the load balancer's backend service | `modules/edge` + `modules/network` firewall rules scoped to the LB health-check and proxy ranges |
| SSH only via Identity-Aware Proxy, from IAP's range alone | `modules/network` firewall rule, asserted by `.tftest.hcl` on the evaluated source range (ISC-349) |
| No firewall rule with `source_ranges` including `0.0.0.0/0` | CONTRACT §6, asserted whole-tree in bats |

## 4. Drive-by attack over plain HTTP

**Threat.** An HTTP listener is a downgrade path and a credential-sniffing
opportunity, and a certificate that never provisions silently leaves one open.

| Mechanism | Where |
|---|---|
| Google-managed TLS certificate on the HTTPS proxy | `modules/edge` |
| HTTP forwarding rule redirects to HTTPS rather than serving | `modules/edge` |
| Uptime checks use `use_ssl = true` **and** `validate_ssl = true` | `modules/observability`, asserted by `.tftest.hcl` — a check tolerating an invalid certificate goes green straight through an expiry |
| Alert policy on uptime-check failure, routed to a named human | `modules/observability`, asserted to have ≥1 notification channel |

## 5. The allowlist mistaken for authentication

**Threat.** The most dangerous row in this table, because the mitigation is
social. An IP allowlist looks like access control in a diagram. It is not one.

| Mechanism | Where |
|---|---|
| Cloud Armor default rule is `deny(403)` — deny-by-default, not allow-by-default | `modules/edge`, asserted on the **evaluated** default rule action by `.tftest.hcl` (ISC-348) |
| `0.0.0.0/0` and `::/0` rejected in every allowlist, including defaults and examples | `modules/env-contract` validation blocks 9 and 10, proven by `expect_failures` (ISC-344) |
| Rate limiting on the security policy | `modules/edge`, `rate_limit_threshold_per_minute` |
| **Stated plainly in this document and in the runbook's verification step** | here; RUNBOOK §3.5 requires testing from a non-allowlisted address |

Nothing in Terraform can stop someone treating the allowlist as a login. The
control is that it is written down, and that the runbook makes you prove the
`403` from outside rather than assume it.

## 6. Cross-environment collision

**Threat.** Two demo environments colliding on a subnet, a hostname, or — worst
— a state file.

| Mechanism | Where |
|---|---|
| `subnet_cidr` unique across the whole map | `modules/env-contract` validation 5 |
| `hostname` unique across the whole map | `modules/env-contract` validation 4, proven by `expect_failures` (ISC-343) |
| Environment key regex `^(demo\|ci)-[1-9][0-9]*$`, key prefix must equal `kind` | `modules/env-contract` validations 1–3, proven by `expect_failures` (ISC-342) |
| Every resource named `${name_prefix}-<role>` with the key embedded | CONTRACT §3, asserted on evaluated names (ISC-351) |
| Per-environment state prefix `osramp/environments/<key>` | Makefile `GCP_TF_PREFIX` |
| **Make rejects `ENV=prod-1`** | Makefile `gcp_tf_require_env`, tested by execution and by mutation |

## 7. The init/apply environment-identity mismatch (CONTRACT §5a)

**Threat.** The highest-risk failure mode in the design, and the one the
original contract did not close. Environment identity was carried in two
independent places — the backend prefix chosen at `init`, and the map key chosen
at `apply` — with nothing making them agree. `init` against
`osramp/environments/demo-1` then apply with `demo-2.tfvars` raises no objection:
a changed backend config is only detected when `init` is re-run, and
`plan`/`apply` silently reuse the cached `.terraform/` backend pointer. The
result is either demo-2's resources written into demo-1's state, or a plan
reading **"destroy demo-1, create demo-2"** into demo-1's state file. Both are
silent, and both are plausible on a tired evening.

Three mechanisms. All three are required; none is sufficient alone.

| # | Mechanism | Where | Proven by |
|---|---|---|---|
| 1 | `target_env` filter — the root instantiates exactly one environment while keeping the whole map in scope, plus a validation that `target_env` exists in the map | `terraform/environments` (F2) | `expect_failures` (ISC-345); Make passes `-var target_env=$(ENV)` |
| 2 | Per-environment `TF_DATA_DIR=.terraform-$(ENV)` — two environments cannot share a cached backend pointer *at all*, so cross-contamination is physically impossible rather than merely detected | Makefile `GCP_TF_DATA_DIR` | contract bats asserts the recorded `TF_DATA_DIR` on **every** invocation; mutation `tf-data-dir.sed` proves the assertion is live |
| 3 | Post-init prefix assertion — read the resolved backend prefix back out of the data dir and abort unless it contains `ENV` | Makefile `gcp_tf_assert_prefix` | contract bats runs it against a fixture whose readback names `demo-9` while `ENV=demo-1` and asserts the abort, paired with a positive; mutation `prefix-assert.sed` proves it |

Mechanism 3 is the belt to the other two braces, and it is the one that catches
a human editing state by hand.

## 8. NAT assumed to control egress

**Threat.** Cloud NAT is often read as an egress control. It is not one. It
provides outbound connectivity for instances with no external IP, and it permits
every outbound connection the firewall allows. A compromised demo VM can reach
anything on the internet through it.

| Mechanism | Where |
|---|---|
| NAT logging on, `nat_log_filter` defaulting to `ERRORS_ONLY`, raisable to `ALL` for an investigation | `modules/network` |
| Egress firewall rules — the actual control, if egress must be constrained | `modules/network` |
| Admin-activity, system-event, policy-denied and data-access logs routed to a dedicated audit bucket the environment's own destroy cannot reach | `modules/observability`, `google_logging_project_sink.admin_activity` |
| **Stated here** so nobody reads the NAT gateway on the diagram as a control | this row |

The audit trail is the compensating control: if egress is not constrained, at
minimum it is recorded, in a bucket that outlives the demo.

## 9. Audit trail deletable by the thing it audits

**Threat.** An audit trail a demo teardown can delete is not an audit trail.

| Mechanism | Where |
|---|---|
| The sink and audit bucket live in `terraform/platform`, never in `terraform/environments` | `modules/observability`, instantiated once by the platform root — `make gcp-tf-destroy ENV=demo-1` physically cannot reach them |
| A **precondition** fails the plan if the audit bucket resolves to the state bucket's name | `modules/observability/main.tf`; it fails, it does not quietly pick another name — a guard that repairs what it detects can never fire |
| Retention policy + lifecycle rule, both derived from `log_retention_days` so they cannot drift apart | same |
| `force_destroy = false`, versioning on, public access prevention enforced | same, asserted on evaluated attributes |
| Sink writer holds `roles/storage.objectCreator`, **not** `objectAdmin` | same — it writes new evidence and cannot delete existing evidence |
| Data-access audit logs explicitly enabled (`DATA_READ`/`DATA_WRITE` are off by default in GCP for every service but IAM) | `google_project_iam_audit_config.data_access` |

## 10. Cost as a security property

Unbounded spend is a denial-of-service against the ability to keep running the
estate, and an unnoticed compromise often shows up first on the bill.

| Mechanism | Where |
|---|---|
| Budget with thresholds at 50%, 80% and 100% | `modules/observability`, asserted on the evaluated threshold list |
| Every alert policy must name ≥1 notification channel, or the plan fails | `notification_channel_ids` validation, proven by `expect_failures` **paired with a positive** |
| Budget gated on `billing_account_id` so the module is usable without billing access — degrading to "no budget", never to "a budget nobody is told about" | `modules/observability` |

See `terraform/COSTS.md` for the figures.

---

## Anti-criteria asserted whole-tree

These are absence properties: `terraform test` can only see what a given plan
evaluated, never what no configuration anywhere contains. They live in bats.

- No `access_config` block (no external IPs).
- No `google_service_account_key`.
- No `google_project_iam_policy`.
- No IAM binding granting `roles/owner` or `roles/editor`.
- No firewall rule with `source_ranges` including `0.0.0.0/0`.
- No `0.0.0.0/0` or `::/0` in any allowlist default or example.
- No real project id, billing account id, domain, or IP address.
- No `terragrunt.hcl`, no `terraform workspace`.
- No secret, token, or key literal.
- No `command = apply` in any `.tftest.hcl`.
