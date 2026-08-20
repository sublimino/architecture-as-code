# ─── The three outputs the Makefile chunk asserts against ────────────────────
#
# CONTRACT.md §5a: `target_env` must equal `ENV` must equal the backend prefix
# suffix, and any disagreement aborts. Two of the three mechanisms live in this
# root; the third is Make reading the resolved backend prefix back out of
# $(TF_DATA_DIR)/terraform.tfstate after init and comparing it. That comparison
# needs the applied environment to be readable as a plain string, which is what
# `terraform output -raw target_env` gives it. Publishing it is therefore not
# decoration — it is the other half of an assertion this root cannot make alone.

output "target_env" {
  description = "The single environment key this root is applying. Make compares this against $(ENV) and against the backend prefix suffix read back after init; any disagreement must abort."
  value       = var.target_env
}

output "target_environment_keys" {
  description = "Keys actually instantiated by this apply. Invariant: exactly one element, equal to target_env. A zero-length value here means the target_env validation was bypassed and the plan is a mass destroy."
  value       = sort(keys(local.target_environments))
}

output "target_environment" {
  description = "Fully resolved values for the targeted environment, exactly as the sibling modules receive them."
  value       = local.target_environments[var.target_env]
}

output "environment_keys" {
  description = "Every environment key this root manages, sorted."
  value       = module.env_contract.environment_keys
}

output "demo_keys" {
  description = "Demo environment keys, sorted."
  value       = module.env_contract.demo_keys
}

output "ci_keys" {
  description = "CI lane keys, sorted."
  value       = module.env_contract.ci_keys
}

output "name_prefix" {
  description = "Per-environment resource name prefix. Every module names its resources <name_prefix>-<role>."
  value       = module.env_contract.name_prefix
}

output "mandatory_labels" {
  description = "Per-environment label set applied to every resource."
  value       = module.env_contract.mandatory_labels
}

output "resolved_environments" {
  description = "Fully resolved per-environment inputs, exactly as the sibling modules will receive them."
  value       = module.env_contract.environments
}

output "uptime_targets" {
  description = "Input for modules/observability: hostname and app_port for DNS-enabled environments."
  value       = module.env_contract.uptime_targets
}

output "integration_inputs" {
  description = "Root-level knobs the commented integration blocks in main.tf will consume. Reviewable before any sibling module exists."
  value       = local.integration_inputs
}

output "edge_environment_keys" {
  description = "Environment keys whose lane really has an HTTPS load balancer. Deliberately derived from the single local.edge_environments definition in main.tf so the published answer and the module graph cannot disagree."
  value       = sort(keys(local.edge_environments))
}

output "access_mode" {
  description = "Effective access path for the targeted environment. Deliberately named access_mode because make gcp-tf-handoff resolves the hand-off field with .access_mode.value // .integration_inputs.value.access_mode; publishing it here makes the hand-off report the real path in force, while the integration_inputs fallback remains for state written before this output existed."
  value       = local.effective_access_mode
}

# ── Hand-off to the test code ───────────────────────────────────────────────
#
# The deploy → test hand-off (`make gcp-tf-handoff`) derives every field from
# `terraform output -json` and REFUSES to write a partial file: a hand-off with
# a blank field is worse than none, because the suite parses it and then reports
# on an estate it never reached. These outputs exist so that refusal never has
# to fire for a healthy environment.
#
# Maps keyed by environment key rather than scalars, so a second demo needs no
# new output block — consistent with the extensibility invariant that adding an
# environment is a tfvars entry and zero .tf edits.

output "instance_names" {
  description = "Compute instance name per environment key. Empty for a ci lane, which has no demo VM."
  value       = { for k, m in module.compute : k => m.instance_name }
}

output "internal_ips" {
  description = "Internal IP per environment key. There is deliberately no external IP to publish."
  value       = { for k, m in module.compute : k => m.internal_ip }
}

output "instance_group_self_links" {
  description = "Unmanaged instance group per environment key, consumed by the edge module when a public frontend is enabled."
  value       = { for k, m in module.compute : k => m.instance_group_self_link }
}

output "network_self_links" {
  description = "VPC self-link per environment key."
  value       = { for k, m in module.network : k => m.network_self_link }
}

# ─── The SSH identity, republished so the hand-off can carry it ──────────────
#
# scripts/gcp-tf/demo-up.sh REFUSES to run without an operator service account:
# without one, every gcloud call below it would run as the human's own
# principal, and on this estate that fails in a way whose error text names
# roles/compute.osLoginExternalUser — a permission an external principal cannot
# grant itself. The diagnosis the error invites is therefore an IAM change
# nobody has the authority to make.
#
# The hand-off writer had NEVER emitted the field — zero occurrences at
# 435f82fe, zero before this — so every `gcp-tf-ts-*`, `gcp-tf-connect` and
# `gcp-tf-public` invocation refused until the operator exported
# GCP_TF_DEMO_OPERATOR_SA by hand. Worse, the refusal's own remedy told them to
# run `make gcp-tf-handoff`, which is precisely the writer that omitted it: the
# advice could not work. This output is what makes that advice true.
#
# Deliberately NOT a map keyed by environment, unlike its neighbours above. The
# operator identity is a project-level singleton owned by the platform root
# (CONTRACT §5b) and is the same for every lane; keying it by environment would
# imply a per-lane identity that does not exist.
#
# Read from the platform root's published output rather than reconstructed from
# a project id and a naming convention. A string built here would be a second
# source of truth for an identity this root does not own, and would keep
# resolving to a plausible-looking address long after the real one moved.
output "operator_sa" {
  description = "The identity a human impersonates for IAP SSH into a lane VM. A project-level singleton from the platform root, identical for every environment, and the field demo-up.sh refuses to run without."
  value       = data.terraform_remote_state.platform.outputs.operator_service_account_email
}
