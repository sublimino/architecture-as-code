---
task: Signal Loom Terraform GCP Demo Platform
project: signalloom-gcp-terraform
slug: 20260818-signalloom-gcp-terraform
effort: E5
phase: verify
progress: 0/357
mode: build
started: 2026-08-18T01:30:00+01:00
updated: 2026-08-18T01:30:00+01:00
---

# ISA — Signal Loom Terraform GCP Demo Platform

Source proposal: `2. Areas/CEO/Enhancement Proposals/Proposal — Signal Loom Terraform GCP Demo Platform (2026-Q3).md`

## Problem

Signal Loom demonstrations today depend on an operator's workstation, an imperative
`scripts/ci/gcp-ci.sh` that creates GCP resources with `gcloud` side effects, and a temporary
ngrok tunnel for public reach. There is no declarative record of what exists in the cloud, no
remote locked state, no managed TLS edge, no allowlist, no audit trail, and no reversible
destroy path scoped to a single environment. Two operators cannot run independent demos, a
failed CI run can leave a 16-vCPU VM burning money, and a customer-facing demo is one laptop
reboot away from being unavailable. Nothing about the estate is reviewable before it is applied.

## Vision

Andy types one reviewed `make` invocation and a named demo environment exists in GCP: private
VM, no public SSH, managed certificate, Cloud Armor default-deny with an explicit allowlist,
its own VPC, its own service account, its own remote state object. He types the paired `down`
target and it is gone — with the state bucket, the audit sink, and every other environment
provably untouched. The euphoric surprise is that the *reversibility* is as credible as the
provisioning: a `destroy` he can read the plan of, that fails closed the moment it is pointed
at a shared foundation or a key that does not match.

## Out of Scope

Application code changes, application authorization redesign, and any production-SLA claim are
excluded. The existing imperative GCP CI estate (`signalloom-ci`, `signalloom-ci-2`, their VPC,
NAT, and service account in `cp-dev-ajm`) is neither imported, replaced, nor destroyed by this
work — it continues to run unchanged alongside. GKE migration, multi-region HA, and
project-per-environment placement are deferred beyond the first increment. Terragrunt is not
adopted. Terraform state bucket deletion is never part of an environment destroy. No live
`terraform apply` against a real GCP project is performed by an autonomous agent; apply is
gated on Andy's reviewed plan and authenticated credentials.

## Principles

- **Declarative beats imperative.** If a resource's existence cannot be read from a file in
  git, it cannot be reviewed, diffed, or safely destroyed.
- **Reversibility is a first-class deliverable, not a byproduct.** Every creating path ships
  with its destroying path, and the destroying path is the one that gets the guard rails.
- **Blast radius is bounded by identity, not by care.** Separate state, separate lock,
  separate service account, separate VPC per environment — so that a mistake in one is
  mechanically incapable of reaching another.
- **Network position is exposure, never identity.** An IP allowlist reduces who can knock; it
  never authenticates who is knocking. Application OIDC stays mandatory behind it.
- **Fail closed on ambiguity.** A missing environment key, an unrecognised key, a mismatched
  confirmation, or a plan touching a protected foundation aborts rather than guesses.
- **The bootstrap must not be able to destroy itself.** A stack that owns its own state bucket
  can delete its own history; the two must be separately authorised artifacts.
- **Extensibility means adding a map entry, not editing a module.** A second demo or a second
  CI lane is data, not code.

## Constraints

- Native Terraform (>= 1.9) with the `hashicorp/google` and `google-beta` providers. No
  Terragrunt, no wrapper DSL, no generated backend blocks in the first increment.
- Remote state in GCS only. No local state, no state in git, no state in the repo tree.
- The state bucket is created by a `terraform/bootstrap` root that is separately applied and
  is NOT the root that consumes the backend. The consuming roots never manage the bucket.
- Backend prefixes are fixed: `osramp/platform` for the protected shared foundation and
  `osramp/environments/<environment-key>` for each environment.
- Terraform workspaces are not the isolation mechanism. Environment keys are.
- Environment keys match `^(demo|ci)-[1-9][0-9]*$`. The key appears in every resource name,
  label, DNS hostname, service account ID, and firewall target.
- No VM carries an external IP. Administrative access is IAP TCP forwarding with OS Login only.
- No service-account JSON keys anywhere. CI authenticates via GitHub Workload Identity
  Federation bound to immutable repository and owner claims.
- Cloud Armor policy default action is `deny(403)`; allow rules are explicit and logged.
- `project_id` is an explicit input, never derived, never defaulted to a real project.
- All Make targets that mutate cloud state require an explicit environment key argument.
- The existing `scripts/ci/gcp-ci.sh` estate is read-only to this work.
- No live `terraform apply`, `gcloud` mutation, DNS record, or state bucket is created by an
  agent. Every cloud-touching step is emitted as a reviewed command for Andy to run.

## Goal

Ship a native-Terraform GCP platform in `terraform/` — a separately bootstrapped GCS state
backend, a typed `demo-N`/`ci-N` environment model, composable modules for network, compute,
secure HTTPS edge, identity, CI lifecycle, and observability, plus a Make lifecycle interface —
such that `terraform fmt`, `validate`, `tflint`, and a policy/contract test suite all pass
offline; every mutating and destructive path is guarded and reversible; and the target branch
`feat/signal-loop-and-bootstrap-refactor` passes its full applicable E2E suite after staged
integration, with the first live demo environment's apply prepared as a reviewed plan awaiting
Andy's authenticated credentials.

## Criteria

### A. Repository scaffolding and conventions

- [ ] ISC-1: `terraform/` exists at repo root and is tracked by git.
- [ ] ISC-2: `terraform/README.md` exists and documents the root layout.
- [ ] ISC-3: `terraform/bootstrap/` root directory exists with its own `.tf` files.
- [ ] ISC-4: `terraform/platform/` root directory exists with its own `.tf` files.
- [ ] ISC-5: `terraform/environments/` root directory exists with its own `.tf` files.
- [ ] ISC-6: `terraform/modules/` exists and contains at least six module directories.
- [ ] ISC-7: `terraform fmt -recursive -check terraform/` exits 0.
- [ ] ISC-8: `.gitignore` ignores `*.tfstate`, `*.tfstate.*`, `.terraform/`, and `*.tfvars` except `*.example.tfvars`.
- [ ] ISC-9: No file matching `*.tfstate*` is tracked by git anywhere in the repo.
- [ ] ISC-10: Every root has a `versions.tf` pinning `required_version >= 1.9`.
- [ ] ISC-11: Every root pins `hashicorp/google` with a `~>` major-minor constraint.
- [ ] ISC-12: Every root pins `hashicorp/google-beta` with the same constraint as `google`.
- [ ] ISC-13: Each root directory contains a `.terraform.lock.hcl` committed to git.
- [ ] ISC-14: Every `.tf` variable declares an explicit `type`.
- [ ] ISC-15: Every `.tf` variable declares a non-empty `description`.
- [ ] ISC-16: `terraform/AGENTS.md` (or a section in the repo `AGENTS.md`) documents the terraform conventions.

### B. State bootstrap — separately authorised, self-protecting

- [ ] ISC-17: `terraform/bootstrap/main.tf` declares a `google_storage_bucket` for Terraform state.
- [ ] ISC-18: The bootstrap root contains NO `backend "gcs"` block (it is local-state or user-supplied).
- [ ] ISC-19: `grep -r 'google_storage_bucket' terraform/platform terraform/environments` returns no state bucket resource.
- [ ] ISC-20: The state bucket sets `uniform_bucket_level_access = true`.
- [ ] ISC-21: The state bucket sets `public_access_prevention = "enforced"`.
- [ ] ISC-22: The state bucket sets `versioning { enabled = true }`.
- [ ] ISC-23: The state bucket sets `force_destroy = false`.
- [ ] ISC-24: The state bucket declares `lifecycle { prevent_destroy = true }`.
- [ ] ISC-25: The state bucket location is an input variable with no real-project default.
- [ ] ISC-26: A `google_storage_bucket_iam_binding` (authoritative) grants `roles/storage.objectAdmin` to named principals only.
- [ ] ISC-27: No IAM binding on the state bucket names `allUsers` or `allAuthenticatedUsers`.
- [ ] ISC-28: The bucket has a lifecycle rule retaining at least N noncurrent versions (N >= 10, variable).
- [ ] ISC-29: The bootstrap root outputs the bucket name.
- [ ] ISC-30: The bootstrap root outputs the backend config block as renderable text.
- [ ] ISC-31: `terraform/bootstrap/backend.hcl.example` exists showing the generated backend config shape.
- [ ] ISC-32: Bootstrap declares a separate log/audit bucket or documents its deferral in a comment.
- [ ] ISC-33: `terraform init -backend=false && terraform validate` succeeds in `terraform/bootstrap`.
- [ ] ISC-34: `tflint --chdir terraform/bootstrap` exits 0.
- [ ] ISC-35: A test asserts the bootstrap root declares no `backend "gcs"` block.
- [ ] ISC-36: A test asserts `prevent_destroy = true` on the state bucket.
- [ ] ISC-37: A test asserts `public_access_prevention = "enforced"` on the state bucket.
- [ ] ISC-38: A test asserts versioning is enabled on the state bucket.
- [ ] ISC-39: A test asserts no consuming root declares a storage bucket for state.
- [ ] ISC-40: The platform root's `backend "gcs"` block uses prefix `osramp/platform`.
- [ ] ISC-41: The environments root's backend prefix is `osramp/environments/<key>` supplied at init.
- [ ] ISC-42: A test asserts the platform backend prefix string is exactly `osramp/platform`.
- [ ] ISC-43: A test asserts the environments backend prefix template contains `osramp/environments/`.
- [ ] ISC-44: `terraform/bootstrap/README.md` documents the one-time bootstrap procedure.
- [ ] ISC-45: The bootstrap README documents the state recovery rehearsal (restore a prior object generation).
- [ ] ISC-46: A `make` target performs the bootstrap and is distinct from every other apply target.

### C. Environment model — typed keys, fail-closed validation

- [ ] ISC-47: A single `environments` map variable defines all environments in one place.
- [ ] ISC-48: The map's value type is an explicit object type, not `any`.
- [ ] ISC-49: The object type includes `kind` constrained to `demo` or `ci`.
- [ ] ISC-50: A `validation` block rejects any key not matching `^(demo|ci)-[1-9][0-9]*$`.
- [ ] ISC-51: A `validation` block rejects a key whose prefix disagrees with its `kind`.
- [ ] ISC-52: A `validation` block rejects duplicate DNS hostnames across environments.
- [ ] ISC-53: A `validation` block rejects duplicate subnet CIDRs across environments.
- [ ] ISC-54: A `validation` block rejects an empty `environments` map for a mutating root.
- [ ] ISC-55: A `validation` block rejects an allowlist entry that is not a valid CIDR.
- [ ] ISC-56: A `validation` block rejects `0.0.0.0/0` in the demo allowlist.
- [ ] ISC-57: A `validation` block rejects `::/0` in the demo allowlist.
- [ ] ISC-58: `project_id` is a required variable with no default.
- [ ] ISC-59: A `validation` block rejects a `project_id` that looks like a placeholder (`CHANGEME`, `example`, empty).
- [ ] ISC-60: A local computes a `name_prefix` per environment that embeds the key.
- [ ] ISC-61: Every resource name in the environment module interpolates the environment key.
- [ ] ISC-62: Every resource carries a `labels` map including `environment = <key>`.
- [ ] ISC-63: Every resource carries a label `managed-by = "terraform"`.
- [ ] ISC-64: Every resource carries a label `component = "signalloom"`.
- [ ] ISC-65: A test asserts the key regex rejects `demo-0`.
- [ ] ISC-66: A test asserts the key regex rejects `demo-01`.
- [ ] ISC-67: A test asserts the key regex rejects `prod-1`.
- [ ] ISC-68: A test asserts the key regex rejects `demo_1`.
- [ ] ISC-69: A test asserts the key regex accepts `demo-1` and `ci-2`.
- [ ] ISC-70: A test asserts a duplicate hostname across two map entries fails validation.
- [ ] ISC-71: A test asserts an overlapping CIDR across two map entries fails validation.
- [ ] ISC-72: `terraform/environments/demo-1.tfvars.example` exists as the worked first-environment input.
- [ ] ISC-73: `terraform/environments/ci-1.tfvars.example` exists as the worked first-CI-lane input.
- [ ] ISC-74: No `.tfvars` file containing a real project ID is committed.
- [ ] ISC-75: Adding a second demo environment requires editing only a tfvars map, provable by a test.

### D. Network module — private by construction

- [ ] ISC-76: `terraform/modules/network/` exists with `main.tf`, `variables.tf`, `outputs.tf`.
- [ ] ISC-77: The module creates a custom-mode VPC (`auto_create_subnetworks = false`).
- [ ] ISC-78: The module creates exactly one subnet per environment with the key in its name.
- [ ] ISC-79: The subnet enables `private_ip_google_access = true`.
- [ ] ISC-80: The subnet enables VPC flow logs.
- [ ] ISC-81: The module creates a Cloud Router.
- [ ] ISC-82: The module creates a Cloud NAT attached to that router.
- [ ] ISC-83: Cloud NAT enables logging with filter `ERRORS_ONLY` or `ALL` (variable).
- [ ] ISC-84: A firewall rule allows TCP 22 from `35.235.240.0/20` (IAP range) only.
- [ ] ISC-85: The IAP SSH rule is scoped by target service account or target tag, not to all instances.
- [ ] ISC-86: A firewall rule allows the GCP health-check ranges `130.211.0.0/22` and `35.191.0.0/16`.
- [ ] ISC-87: The health-check rule permits only the backend service port, not all ports.
- [ ] ISC-88: A default-deny ingress rule exists at the lowest priority.
- [ ] ISC-89: No firewall rule has `source_ranges` containing `0.0.0.0/0` on any port.
- [ ] ISC-90: An egress rule set exists that is explicit rather than relying on the implied allow-all.
- [ ] ISC-91: The egress policy is documented in a comment naming the allowed dependencies.
- [ ] ISC-92: A test asserts no firewall rule allows `0.0.0.0/0` ingress.
- [ ] ISC-93: A test asserts the SSH rule source is exactly the IAP range.
- [ ] ISC-94: A test asserts the health-check rule sources are exactly the two GCP ranges.
- [ ] ISC-95: A test asserts `auto_create_subnetworks` is false.
- [ ] ISC-96: A test asserts flow logs are enabled on every subnet.
- [ ] ISC-97: The module outputs the network self-link, subnet self-link, and CIDR.
- [ ] ISC-98: `tflint --chdir terraform/modules/network` exits 0.

### E. Compute module — the demo VM

- [ ] ISC-99: `terraform/modules/compute/` exists with `main.tf`, `variables.tf`, `outputs.tf`.
- [ ] ISC-100: The instance declares no `access_config` block (no external IP).
- [ ] ISC-101: A test asserts no `access_config` appears anywhere under `terraform/`.
- [ ] ISC-102: The instance sets metadata `enable-oslogin = "TRUE"`.
- [ ] ISC-103: A test asserts `enable-oslogin` is TRUE on every instance.
- [ ] ISC-104: The instance disables project-wide SSH keys (`block-project-ssh-keys = "TRUE"`).
- [ ] ISC-105: The instance enables Shielded VM: secure boot, vTPM, and integrity monitoring.
- [ ] ISC-106: A test asserts all three Shielded VM fields are true.
- [ ] ISC-107: The instance sets `confidential_instance_config` or documents why not.
- [ ] ISC-108: The boot disk sets an explicit size and type from variables.
- [ ] ISC-109: The instance attaches a per-environment runtime service account, not the default compute SA.
- [ ] ISC-110: A test asserts no instance uses `<project-number>-compute@developer.gserviceaccount.com`.
- [ ] ISC-111: The instance's SA scopes are `cloud-platform` with IAM doing the restricting.
- [ ] ISC-112: The instance carries a network tag derived from the environment key.
- [ ] ISC-113: The machine type is a variable with a documented default.
- [ ] ISC-114: `demo-N` instances declare no scheduling preemptibility.
- [ ] ISC-115: `ci-N` instances are separately typed and may be suspended.
- [ ] ISC-116: `deletion_protection` is a variable, defaulting true for `demo`, false for `ci`.
- [ ] ISC-117: A startup script or metadata reference exists and is version-controlled.
- [ ] ISC-118: The startup script does not embed any secret literal.
- [ ] ISC-119: A test greps the module tree for high-entropy literals and finds none.
- [ ] ISC-120: The module outputs the instance self-link, internal IP, and instance group.
- [ ] ISC-121: `tflint --chdir terraform/modules/compute` exits 0.

### F. Secure edge — HTTPS LB, managed TLS, Cloud Armor

- [ ] ISC-122: `terraform/modules/edge/` exists with `main.tf`, `variables.tf`, `outputs.tf`.
- [ ] ISC-123: The module creates a global external HTTPS load balancer forwarding rule.
- [ ] ISC-124: The module creates a `google_compute_managed_ssl_certificate` or Certificate Manager cert.
- [ ] ISC-125: The module creates an HTTP forwarding rule that only redirects to HTTPS.
- [ ] ISC-126: A test asserts no forwarding rule serves plaintext content on port 80.
- [ ] ISC-127: The backend service references a health check on the application port.
- [ ] ISC-128: The backend service enables Cloud CDN only if explicitly opted in (default off).
- [ ] ISC-129: The backend service enables logging with a sample rate of 1.0.
- [ ] ISC-130: A `google_compute_security_policy` (Cloud Armor) is attached to the backend service.
- [ ] ISC-131: The Cloud Armor default rule at priority 2147483647 is `deny(403)`.
- [ ] ISC-132: A test asserts the Cloud Armor default rule action is a deny, not an allow.
- [ ] ISC-133: Allow rules are generated from the allowlist variable with one rule per CIDR group.
- [ ] ISC-134: Every Cloud Armor deny rule sets `preview = false` in the applied config.
- [ ] ISC-135: A test asserts no Cloud Armor rule is left in `preview = true`.
- [ ] ISC-136: Cloud Armor adaptive protection (Layer 7 DDoS) is enabled.
- [ ] ISC-137: A rate-limit rule exists with an explicit threshold and ban duration.
- [ ] ISC-138: A test asserts a rate-limit rule exists with a finite threshold.
- [ ] ISC-139: Cloud Armor preconfigured WAF rules for SQLi and XSS are referenced.
- [ ] ISC-140: The security policy sets `log_level = "VERBOSE"` in advanced options.
- [ ] ISC-141: A test asserts deny rules are logged.
- [ ] ISC-142: The TLS policy pins a minimum TLS version of 1.2.
- [ ] ISC-143: A test asserts no SSL policy permits TLS below 1.2.
- [ ] ISC-144: The module creates a DNS A record only when a managed zone input is supplied.
- [ ] ISC-145: The DNS hostname embeds the environment key.
- [ ] ISC-146: A test asserts each environment's hostname is unique across the map.
- [ ] ISC-147: The module documents in prose that the allowlist is exposure control, not authentication.
- [ ] ISC-148: The backend rejects requests carrying client-supplied identity headers (documented + a test on the config).
- [ ] ISC-149: A negative-access test script exists that probes an unlisted source and expects 403.
- [ ] ISC-150: A positive-access test script exists that probes an allowlisted source and expects the auth boundary (302/401), not 200 anonymous.
- [ ] ISC-151: A backend-bypass test script exists that probes the VM's internal IP from outside and expects no route.
- [ ] ISC-152: The three edge probe scripts are executable, shellcheck-clean, and runnable offline in dry-run mode.
- [ ] ISC-153: The module outputs the LB IP address and the certificate resource name.
- [ ] ISC-154: `tflint --chdir terraform/modules/edge` exits 0.

### G. Identity — WIF, service accounts, least privilege

- [ ] ISC-155: `terraform/modules/identity/` exists with `main.tf`, `variables.tf`, `outputs.tf`.
- [ ] ISC-156: A `google_iam_workload_identity_pool` is declared.
- [ ] ISC-157: A `google_iam_workload_identity_pool_provider` for GitHub OIDC is declared.
- [ ] ISC-158: The provider's issuer URI is exactly `https://token.actions.githubusercontent.com`.
- [ ] ISC-159: The provider declares an `attribute_condition` — it is not null or empty.
- [ ] ISC-160: A test asserts `attribute_condition` is present and non-empty.
- [ ] ISC-161: The attribute condition pins `assertion.repository_owner_id` (immutable numeric), not just the name.
- [ ] ISC-162: A test asserts the condition references a `_id` claim, not only string names.
- [ ] ISC-163: The attribute condition pins the repository to the osramp-demo repo.
- [ ] ISC-164: The attribute condition pins an approved ref or workflow.
- [ ] ISC-165: A test asserts the condition is not the tautology `true`.
- [ ] ISC-166: No `google_service_account_key` resource exists anywhere under `terraform/`.
- [ ] ISC-167: A test greps for `google_service_account_key` and finds zero matches.
- [ ] ISC-168: One service account per environment is created with the key in its account ID.
- [ ] ISC-169: A separate CI-plan service account and CI-apply service account are distinguished.
- [ ] ISC-170: No IAM binding in the tree grants `roles/owner`.
- [ ] ISC-171: No IAM binding in the tree grants `roles/editor`.
- [ ] ISC-172: A test asserts neither `roles/owner` nor `roles/editor` appears in any IAM binding.
- [ ] ISC-173: IAM uses `google_project_iam_member` (additive) rather than `google_project_iam_policy` (authoritative, destructive).
- [ ] ISC-174: A test asserts no `google_project_iam_policy` resource exists.
- [ ] ISC-175: The WIF principal binding is scoped by subject/attribute, not to the whole pool.
- [ ] ISC-176: A test asserts the WIF member string is not the bare `principalSet://.../*`.
- [ ] ISC-177: IAP TCP tunnel access is granted via `roles/iap.tunnelResourceAccessor` to named principals.
- [ ] ISC-178: OS Login roles are granted per-environment, not project-wide admin.
- [ ] ISC-179: A documented WIF claim-negative test exists (wrong repo → denied).
- [ ] ISC-180: `tflint --chdir terraform/modules/identity` exits 0.

### H. CI lifecycle — named lanes that always suspend

- [ ] ISC-181: `terraform/modules/ci-runner/` exists with `main.tf`, `variables.tf`, `outputs.tf`.
- [ ] ISC-182: Each CI lane gets its own instance named for its key.
- [ ] ISC-183: Each CI lane gets its own service account.
- [ ] ISC-184: Each CI lane's instance carries label `ci-lane = <key>`.
- [ ] ISC-185: A lifecycle script `scripts/ci/gcp-tf-ci.sh` exists implementing resume→test→suspend.
- [ ] ISC-186: The lifecycle script suspends the VM on the test-pass path.
- [ ] ISC-187: The lifecycle script suspends the VM on the test-fail path.
- [ ] ISC-188: A test asserts both the pass and fail paths reach a suspend call.
- [ ] ISC-189: The suspend runs from a trap so an interrupted run still suspends.
- [ ] ISC-190: The trap does not override the script's exit status (errexit trap hazard).
- [ ] ISC-191: A test asserts a failing final command in the trap cannot rewrite a passing exit code.
- [ ] ISC-192: The lifecycle script takes a per-lane lock keyed on the CI key.
- [ ] ISC-193: A test asserts two different lanes do not contend on the same lock name.
- [ ] ISC-194: A stale-runner reaper exists (script or Cloud Scheduler config) that suspends VMs idle beyond a threshold.
- [ ] ISC-195: The reaper's idle threshold is a variable, not a magic number.
- [ ] ISC-196: A test asserts the reaper only targets instances labelled `ci-lane`.
- [ ] ISC-197: A test asserts the reaper never targets a `demo` environment.
- [ ] ISC-198: The lifecycle script `unset`s or empties `SSH_AUTH_SOCK` before any `gcloud compute ssh`.
- [ ] ISC-199: A test asserts the SSH_AUTH_SOCK guard is present in the script.
- [ ] ISC-200: The script is `shellcheck`-clean.
- [ ] ISC-201: A fake-client test exercises the script's control flow without touching GCP.
- [ ] ISC-202: The fake-client test covers the pass path, the fail path, and the interrupt path.
- [ ] ISC-203: The existing `scripts/ci/gcp-ci.sh` is byte-identical to its pre-change state.

### I. Observability, audit, and cost

- [ ] ISC-204: `terraform/modules/observability/` exists with `main.tf`, `variables.tf`, `outputs.tf`.
- [ ] ISC-205: A `google_logging_project_sink` routes admin activity logs to a dedicated bucket.
- [ ] ISC-206: The log sink's destination bucket is separate from the Terraform state bucket.
- [ ] ISC-207: A test asserts the log destination is not the state bucket.
- [ ] ISC-208: The log bucket sets a retention policy from a variable.
- [ ] ISC-209: Data-access audit log config is declared for the applicable services.
- [ ] ISC-210: A `google_monitoring_uptime_check_config` exists per `demo-N` hostname.
- [ ] ISC-211: An alert policy fires on uptime-check failure.
- [ ] ISC-212: An alert policy fires on LB backend unhealthy.
- [ ] ISC-213: Alert policies reference a notification channel variable (named owners).
- [ ] ISC-214: A test asserts every alert policy has at least one notification channel.
- [ ] ISC-215: A `google_billing_budget` is declared with thresholds at 50%, 80%, and 100%.
- [ ] ISC-216: A test asserts all three budget thresholds are present.
- [ ] ISC-217: The budget is gated behind a variable so it is skippable without billing-account access.
- [ ] ISC-218: `terraform/COSTS.md` documents per-demo VM, NAT, LB, Cloud Armor, logging, and state cost drivers.
- [ ] ISC-219: `terraform/COSTS.md` states an order-of-magnitude monthly figure per demo environment.
- [ ] ISC-220: `tflint --chdir terraform/modules/observability` exits 0.

### J. Make interface — explicit, guarded, reversible

- [ ] ISC-221: `make gcp-tf-bootstrap` exists and is declared `.PHONY`.
- [ ] ISC-222: `make gcp-tf-plan ENV=<key>` exists.
- [ ] ISC-223: `make gcp-tf-apply ENV=<key>` exists.
- [ ] ISC-224: `make gcp-tf-status ENV=<key>` exists.
- [ ] ISC-225: `make gcp-tf-test ENV=<key>` exists.
- [ ] ISC-226: `make gcp-tf-destroy ENV=<key>` exists.
- [ ] ISC-227: `make gcp-tf-validate` exists and runs fmt + validate + tflint offline.
- [ ] ISC-228: `make gcp-tf-ci CI=<key>` exists.
- [ ] ISC-229: Every mutating target aborts with a non-zero exit when `ENV` is unset.
- [ ] ISC-230: A test asserts `make gcp-tf-apply` without `ENV` exits non-zero.
- [ ] ISC-231: A test asserts `make gcp-tf-destroy` without `ENV` exits non-zero.
- [ ] ISC-232: Every mutating target aborts when `ENV` fails the key regex.
- [ ] ISC-233: A test asserts `ENV=prod-1` is rejected by the apply target.
- [ ] ISC-234: `gcp-tf-destroy` requires a typed confirmation matching the environment key.
- [ ] ISC-235: A test asserts a mismatched confirmation aborts the destroy.
- [ ] ISC-236: `gcp-tf-destroy` refuses to run against the `platform` or `bootstrap` roots.
- [ ] ISC-237: A test asserts the destroy target's target list excludes the state bucket.
- [ ] ISC-238: `gcp-tf-apply` requires a saved plan file rather than applying from scratch.
- [ ] ISC-239: A test asserts apply references a `-out`/plan file argument.
- [ ] ISC-240: Every new target has a `##` help comment consistent with the existing Makefile style.
- [ ] ISC-241: A test asserts every `gcp-tf-*` target appears in `make help` output.
- [ ] ISC-242: Targets use `$(MAKE)` for recursion, matching repo convention.
- [ ] ISC-243: No new target hardcodes a project ID.
- [ ] ISC-244: A test greps the Makefile's new targets for a hardcoded project ID and finds none.
- [ ] ISC-245: `make gcp-tf-validate` completes with no network access.
- [ ] ISC-246: The Make targets do not shadow or rename any existing `ci-*` target.
- [ ] ISC-247: A test asserts `ci-gcp`, `ci-gcp-2`, `ci-provision`, and `ci-status` still exist and are unchanged.

### K. Tests, CI wiring, and documentation

- [ ] ISC-248: `test/terraform-conventions.bats` exists and runs offline.
- [ ] ISC-249: `test/terraform-state-protection.bats` exists and runs offline.
- [ ] ISC-250: `test/terraform-environment-keys.bats` exists and runs offline.
- [ ] ISC-251: `test/terraform-network-security.bats` exists and runs offline.
- [ ] ISC-252: `test/terraform-edge-security.bats` exists and runs offline.
- [ ] ISC-253: `test/terraform-identity.bats` exists and runs offline.
- [ ] ISC-254: `test/terraform-make-contract.bats` exists and runs offline.
- [ ] ISC-255: `test/terraform-ci-lifecycle.bats` exists and runs offline.
- [ ] ISC-256: Every new bats file runs green with `bats <file>`.
- [ ] ISC-257: The full new bats suite completes in under 120 seconds.
- [ ] ISC-258: Every new bats file asserts the mechanism under test is present before asserting its behaviour.
- [ ] ISC-259: A mutation check proves at least one assertion per new file actually fails when the code is broken.
- [ ] ISC-260: No new bats test passes when its target file is deleted.
- [ ] ISC-261: The new tests are reachable from an existing aggregate test target.
- [ ] ISC-262: A test asserts the new bats files are discovered by that aggregate target.
- [ ] ISC-263: `.github/workflows/` gains or extends a job running `make gcp-tf-validate`.
- [ ] ISC-264: The CI job runs on pull request against the target branch.
- [ ] ISC-265: The CI job requires no GCP credentials.
- [ ] ISC-266: `terraform/README.md` documents the bootstrap → platform → environment ordering.
- [ ] ISC-267: `terraform/README.md` documents the destroy path and what it deliberately excludes.
- [ ] ISC-268: `terraform/RUNBOOK.md` documents the first-demo-environment procedure step by step.
- [ ] ISC-269: The runbook names every prerequisite Andy must supply (project, DNS zone, allowlist, billing account).
- [ ] ISC-270: The runbook includes the exact `gcloud auth` commands to run before the first apply.
- [ ] ISC-271: `terraform/SECURITY.md` maps each proposal threat row to the implementing resource.
- [ ] ISC-272: Every threat row in the proposal's Security and Risk table has a named mitigation in `SECURITY.md`.
- [ ] ISC-273: `terraform/SECURITY.md` states explicitly that the allowlist is not authentication.
- [ ] ISC-274: The proposal's Obsidian project folder exists with its folder note.
- [ ] ISC-275: The Obsidian project note links back to the proposal.

### L. Anti-criteria — what must NOT happen

- [ ] ISC-276: Anti: no `terraform apply`, `terraform destroy`, or `gcloud` mutation is executed by an agent.
- [ ] ISC-277: Anti: no GCS bucket, GCE instance, DNS record, or IAM binding exists in GCP as a result of this session without Andy's explicit run.
- [ ] ISC-278: Anti: `scripts/ci/gcp-ci.sh` is not modified — `git diff` on it is empty.
- [ ] ISC-279: Anti: `scripts/ci/vm-pipeline.sh` is not modified.
- [ ] ISC-280: Anti: `scripts/ci/ci-lock.sh` is not modified.
- [ ] ISC-281: Anti: no existing Makefile target's recipe is changed.
- [ ] ISC-282: Anti: no existing test file under `test/` or `d2-signalloom/test/` is modified.
- [ ] ISC-283: Anti: no `*.tfstate` file is created in the repo tree.
- [ ] ISC-284: Anti: no `.terraform/` directory is committed.
- [ ] ISC-285: Anti: no credential, token, or private key literal appears in any new file.
- [ ] ISC-286: Anti: no new file contains a hardcoded absolute path under `/home/andy`.
- [ ] ISC-287: Anti: no Terraform resource in the tree permits ingress from `0.0.0.0/0`.
- [ ] ISC-288: Anti: no VM in the tree has an external IP.
- [ ] ISC-289: Anti: no service account key resource is declared.
- [ ] ISC-290: Anti: no IAM binding grants owner or editor.
- [ ] ISC-291: Anti: the environment destroy path cannot reach the state bucket.
- [ ] ISC-292: Anti: the environment destroy path cannot reach the log/audit sink.
- [ ] ISC-293: Anti: no Terragrunt file (`terragrunt.hcl`) is introduced.
- [ ] ISC-294: Anti: no Terraform workspace command appears in the Make targets.
- [ ] ISC-295: Anti: no agent commits directly to `feat/signal-loop-and-bootstrap-refactor`.
- [ ] ISC-296: Anti: no agent worktree is created inside the repository tree.
- [ ] ISC-297: Anti: no `.keys/` material is regenerated or moved.
- [ ] ISC-298: Anti: the dashboard, fleet, and application manifests are unchanged.
- [ ] ISC-299: Anti: no test is marked skipped to make the suite green.
- [ ] ISC-300: Anti: no guard auto-repairs the condition it is meant to detect.

### M. Integration — worktrees, staged merge, target-branch E2E

- [ ] ISC-301: Each code-writing agent works in its own worktree under `~/src/.worktrees/osramp-demo/`.
- [ ] ISC-302: No worktree directory is created inside `/home/andy/src/cp/osramp-demo`.
- [ ] ISC-303: Every agent branch is created from the current tip of the target branch.
- [ ] ISC-304: Every agent branch has at least one commit (zero commits is treated as failure, not idleness).
- [ ] ISC-305: Every agent branch's working tree is clean at hand-off.
- [ ] ISC-306: Each agent branch is rebased onto the target branch tip before merge.
- [ ] ISC-307: Each branch's own tests pass in its worktree before merge.
- [ ] ISC-308: Branches are merged one at a time, with tests run between merges.
- [ ] ISC-309: After each merge, `terraform fmt -recursive -check` still passes.
- [ ] ISC-310: After each merge, `terraform validate` still passes on every root.
- [ ] ISC-311: After each merge, the full new bats suite still passes.
- [ ] ISC-312: After the final merge, `make help` still parses and lists every target.
- [ ] ISC-313: After the final merge, the pre-existing repo test suite shows no new failures versus a captured baseline.
- [ ] ISC-314: The baseline is captured on the target branch tip BEFORE any merge.
- [ ] ISC-315: The post-merge and baseline results are diffed and the diff reported.
- [ ] ISC-316: Commits are unsigned or signed to match the branch's existing `%G?` practice.
- [ ] ISC-317: Commit messages follow the repo's conventional-commit style with a scope.
- [ ] ISC-318: No commit message quotes a hash that was not read back from git.
- [ ] ISC-319: The final state of the target branch is reported with an actual commit hash read from `git log`.
- [ ] ISC-320: Every agent is confirmed terminated, with no background process left running.
- [ ] ISC-321: Antecedent: the first demo environment's `terraform plan` output is produced and reviewable before any apply is proposed.

### N. Native Terraform tests — plan-time assertions against evaluated config

- [ ] ISC-322: `terraform/bootstrap/tests/*.tftest.hcl` exists.
- [ ] ISC-323: `terraform/platform/tests/*.tftest.hcl` exists.
- [ ] ISC-324: `terraform/environments/tests/*.tftest.hcl` exists.
- [ ] ISC-325: `terraform/modules/env-contract/tests/*.tftest.hcl` exists.
- [ ] ISC-326: `terraform/modules/network/tests/*.tftest.hcl` exists.
- [ ] ISC-327: `terraform/modules/compute/tests/*.tftest.hcl` exists.
- [ ] ISC-328: `terraform/modules/edge/tests/*.tftest.hcl` exists.
- [ ] ISC-329: `terraform/modules/identity/tests/*.tftest.hcl` exists.
- [ ] ISC-330: `terraform/modules/ci-runner/tests/*.tftest.hcl` exists.
- [ ] ISC-331: `terraform/modules/observability/tests/*.tftest.hcl` exists.
- [ ] ISC-332: Every `.tftest.hcl` declares `mock_provider "google"`.
- [ ] ISC-333: A test asserts no `.tftest.hcl` omits a `mock_provider` block.
- [ ] ISC-334: Anti: no `.tftest.hcl` uses `command = apply`.
- [ ] ISC-335: A test asserts zero occurrences of `command = apply` under `terraform/`.
- [ ] ISC-336: `terraform test` passes in `terraform/bootstrap` with no network access.
- [ ] ISC-337: `terraform test` passes in every module directory with no network access.
- [ ] ISC-338: `terraform test` passes in `terraform/environments` with no network access.
- [ ] ISC-339: A tftest asserts the state bucket's evaluated `public_access_prevention` is `enforced`.
- [ ] ISC-340: A tftest asserts the state bucket's evaluated `force_destroy` is `false`.
- [ ] ISC-341: A tftest asserts the state bucket's evaluated `versioning` is enabled.
- [ ] ISC-342: A tftest uses `expect_failures` to prove the environment-key regex rejects `prod-1`.
- [ ] ISC-343: A tftest uses `expect_failures` to prove a duplicate hostname is rejected.
- [ ] ISC-344: A tftest uses `expect_failures` to prove `0.0.0.0/0` in an allowlist is rejected.
- [ ] ISC-345: A tftest uses `expect_failures` to prove a `target_env` absent from the map is rejected.
- [ ] ISC-346: Every `expect_failures` run is paired with a positive run proving the corrected input passes.
- [ ] ISC-347: A test asserts every `.tftest.hcl` containing `expect_failures` also contains a passing `run`.
- [ ] ISC-348: A tftest asserts the evaluated Cloud Armor default rule action is `deny(403)`.
- [ ] ISC-349: A tftest asserts the evaluated firewall SSH rule source is exactly the IAP range.
- [ ] ISC-350: A tftest asserts the evaluated WIF provider `attribute_condition` is non-empty.
- [ ] ISC-351: A tftest asserts evaluated resource names embed the environment key.
- [ ] ISC-352: A tftest asserts evaluated labels include `environment`, `managed-by`, and `component`.
- [ ] ISC-353: `make gcp-tf-test-unit` runs every `terraform test` suite offline.
- [ ] ISC-354: `make gcp-tf-validate` invokes `gcp-tf-test-unit`.
- [ ] ISC-355: A test asserts every directory containing `.tf` files with resources has a `tests/` directory.
- [ ] ISC-356: The whole `terraform test` sweep completes in under 300 seconds.
- [ ] ISC-357: Anti: no `.tftest.hcl` requires cloud credentials — the sweep passes with `CLOUDSDK_CORE_ACCOUNT` unset and no ADC.

## Test Strategy

| isc | type | check | threshold | tool |
|-----|------|-------|-----------|------|
| ISC-1..16 | static | repo layout, fmt, pins, gitignore | all pass | `fd`, `terraform fmt`, `bats` |
| ISC-17..46 | static | state bucket hardening + separation | all pass | `rg`, `terraform validate`, `bats` |
| ISC-47..75 | static+negative | key regex and collision validation | invalid keys rejected | `terraform validate`, `bats` |
| ISC-76..98 | static | network privacy invariants | zero `0.0.0.0/0` ingress | `rg`, `tflint`, `bats` |
| ISC-99..121 | static | VM hardening invariants | zero external IPs | `rg`, `bats` |
| ISC-122..154 | static+script | edge posture; probe scripts dry-run | default-deny present | `rg`, `shellcheck`, `bats` |
| ISC-155..180 | static | WIF claim pinning, no keys, no owner/editor | zero matches | `rg`, `bats` |
| ISC-181..203 | behavioural | fake-client lifecycle: pass/fail/interrupt | all three suspend | `bats`, `shellcheck` |
| ISC-204..220 | static | sinks, alerts, budgets, cost doc | all present | `rg`, `bats` |
| ISC-221..247 | contract | Make target existence + fail-closed behaviour | non-zero on missing/bad ENV | `make`, `bats` |
| ISC-248..275 | meta | tests exist, run green, and can fail | mutation check passes | `bats` |
| ISC-276..300 | anti | forbidden patterns absent | zero matches | `rg`, `git diff` |
| ISC-301..321 | process | worktree hygiene, staged merge, baseline diff | no new failures | `git`, `make`, `bats` |

## Features

| name | description | satisfies | depends_on | parallelizable |
|------|-------------|-----------|------------|----------------|
| F1-foundation | Repo scaffolding, versions/provider pins, bootstrap state root, backend config, state protection tests | ISC-1..46 | — | yes |
| F2-envmodel | Typed environment map, validation blocks, naming/labelling locals, tfvars examples, key tests | ISC-47..75 | F1 (conventions only) | yes |
| F3-network-compute | Network module (VPC/subnet/NAT/firewall/IAP) and compute module (private hardened VM) | ISC-76..121 | F2 (contract) | yes |
| F4-edge | HTTPS LB, managed TLS, Cloud Armor default-deny, DNS, negative/positive/bypass probe scripts | ISC-122..154 | F3 (contract) | yes |
| F5-identity-ci | WIF provider with pinned claims, per-purpose SAs, least-privilege IAM, CI lane module, lifecycle script, reaper | ISC-155..203 | F2 (contract) | yes |
| F6-obs-make-docs | Observability/audit/budget module, Make lifecycle interface, README/RUNBOOK/SECURITY/COSTS, CI workflow job | ISC-204..275 | F1..F5 (interface names) | yes |
| F7-integration | Rebase, staged merge, baseline capture and diff, full target-branch E2E, anti-criteria sweep | ISC-276..321 | F1..F6 | no |

## Decisions

- **2026-08-18T01:30** — Terraform tree rooted at `terraform/` rather than extending
  `d2-osramp-fleet/terraform/`. The fleet root is a Kubernetes/Helm/Flux root with no GCP
  provider and a different lifecycle owner; mixing cloud-account provisioning into it would
  couple demo-cluster teardown to cloud-estate teardown.
- **2026-08-18T01:30** — Three roots (`bootstrap`, `platform`, `environments`) rather than one.
  The proposal's non-negotiable is that the state-consuming root cannot own the state bucket;
  the cleanest enforcement is a separate root with no backend block, provable by grep.
- **2026-08-18T01:30** — Agents are prohibited from any live cloud mutation. `gcloud` in this
  session has no active account and `~/.config/gcloud` is unwritable from every Bash call, so
  a live apply is not merely risky, it is impossible; the deliverable is a reviewed plan plus
  a runbook. Recorded because the proposal's approval gate demands the same thing independently.
- **2026-08-18T01:30** — Existing imperative CI estate is frozen, not migrated. The proposal
  places it out of scope, and a byte-identical `git diff` on those three scripts is cheaper to
  verify than an import.

## Changelog

_(populated at LEARN)_

## Verification

Evidence captured on branch `feat/signal-loop-and-bootstrap-refactor`, commit `a6fab16`.
Every command below was run offline with no cloud credentials.

**Aggregate**

- `make gcp-tf-validate` with `CLOUDSDK_CORE_ACCOUNT` and `GOOGLE_APPLICATION_CREDENTIALS`
  unset — PASS. Satisfies ISC-227, ISC-245, ISC-353, ISC-354, ISC-357.
- Native `terraform test` sweep, 10 roots/modules, 160 assertions, 0 failed:
  bootstrap 9, environments 13, ci-runner 16, compute 11, edge 28, env-contract 28,
  identity 24, network 13, observability 9, platform 9. Satisfies ISC-322..338, ISC-356.
- `test/terraform-*.bats`, 9 suites, 223 assertions, 0 failed: ci-lifecycle 26,
  conventions 24, edge-security 22, environment-keys 14, identity 33, make-contract 35,
  network-security 27, state-protection 28, suite-registration 14. Satisfies ISC-248..262.
- `terraform fmt -recursive -check terraform/` — exit 0. ISC-7, ISC-309.
- `tflint` — exit 0 on every module. ISC-34, ISC-98, ISC-121, ISC-154, ISC-180, ISC-220.

**Regression against baseline**

- Baseline captured at `ce088ae` BEFORE any merge (ISC-314): 46 files, 562 ok, 7 not-ok
  across 3 files (`api-adversarial`, `flux-substitution`, `test-count-floor`).
- Post-merge: 55 files, 810 ok. Three failures appeared and were traced (ISC-315):
  two were mine (VAC003 vacuous assertions in `terraform-ci-lifecycle.bats` and
  `terraform-make-contract.bats`) and are fixed; one (`acceptance-spec-coverage`,
  `live-data.spec.ts` missing a registry row) came from a concurrent session's commits
  `d542b6a`/`0ba48fe`, not from this work.
- `make help` target diff before vs after: **zero targets removed**, nine added.
  ISC-246, ISC-247, ISC-312.

**Frozen estate (ISC-278..280, ISC-203)**

- `git diff --name-only ce088ae <branch>` for all six chunk branches against
  `scripts/ci/gcp-ci.sh`, `vm-pipeline.sh`, `ci-lock.sh` — **0 files for every branch**.
  `vm-pipeline.sh` did change on the target branch, from concurrent commit `d1abaac`
  (three image-push steps), which is outside this work; the digest fixture was
  re-recorded against that commit with the reason written into the fixture.

**Guards proven able to fail (ISC-259, ISC-300)**

- Bootstrap tftest: flipping `public_access_prevention` to `inherited` in a staged copy
  turned the suite red (8 passed, 1 failed); the real tree was verified unchanged after.
- Committed mutation fixtures exist for: `access_config` injected, firewall widened to
  `0.0.0.0/0`, secret literal in the startup script, Cloud Armor default flipped to allow,
  default rule deleted, rule left in `preview = true`, allowlist silently truncated,
  service-account key declared, authoritative `iam_policy`, owner binding, editor binding,
  `storage.admin` on the state bucket, key regex widened, confirmation neutered, bats glob
  reverted to a hand list, tftest directories hand-listed.
- `test/vacuous-assertions.bats` (the repo's own VAC scanner) — 39 assertions, PASS.

**Not verified — and why**

- No `terraform plan`, `apply`, `destroy`, or `init` against a real backend has run.
  `gcloud`'s active account is `sublimino@gmail.com`, which cannot reach `cp-dev-ajm`;
  `andy@control-plane.io` is authenticated but requires reauthentication that cannot be
  completed non-interactively. ISC-321 (the reviewable first plan) is therefore
  **[DEFERRED-VERIFY]**, blocked on Andy running `gcloud auth login` and supplying the
  project, DNS zone, allowlist, billing account, and GitHub owner id named in `RUNBOOK.md`.
- ISC-277 holds by construction: no GCP resource exists as a result of this work.
