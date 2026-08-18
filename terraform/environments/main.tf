# The environment root.
#
# ─── What is live and what is not ───────────────────────────────────────────
#
# `module.env_contract` is live: it types, validates and resolves the whole
# environment map, and this root can `terraform validate` on its own today.
#
# Every other module block is commented out because it is owned by a sibling
# chunk building in a parallel worktree (`terraform/CONTRACT.md` §1) and does
# not exist in this branch. Writing them speculatively as live blocks would
# make this root un-validatable, which would in turn make the validation tests
# un-runnable — the tests are the deliverable here, so the root stays green.
#
# `terraform/environments/WIRING.md` lists the exact uncommenting order.
#
# ─── The extensibility invariant (ISC-75) ───────────────────────────────────
#
# Note what is NOT below: there is no per-environment block anywhere. Every
# module call is a single `for_each` over `module.env_contract.environments`,
# and each reads `each.value.<input>`. Adding `demo-2` is therefore one new
# entry in a tfvars map and zero `.tf` edits. `demo-1-and-demo-2.tfvars.example`
# is the worked proof, and the bats suite asserts it byte-for-byte differs from
# the single-environment example only inside the tfvars file.

module "env_contract" {
  source = "../modules/env-contract"

  environments = var.environments
}

# Values the commented module blocks below will consume at integration.
# Publishing them through an output means the wiring can be reviewed — and the
# resolved names, labels and allowlists inspected — before any sibling module
# exists, rather than being discovered at the first real plan.
locals {
  integration_inputs = {
    project_id                      = var.project_id
    project_number                  = var.project_number
    dns_managed_zone                = var.dns_managed_zone
    nat_log_filter                  = var.nat_log_filter
    startup_script_path             = var.startup_script_path
    rate_limit_threshold_per_minute = var.rate_limit_threshold_per_minute
    enable_cdn                      = var.enable_cdn
    ci_idle_suspend_minutes         = var.ci_idle_suspend_minutes
    github_owner_id                 = var.github_owner_id
    github_repository               = var.github_repository
    github_allowed_ref              = var.github_allowed_ref
  }
}

# ════════════════════════════════════════════════════════════════════════════
# INTEGRATION BLOCK — ACTIVATED ONLY AFTER THE SIBLING CHUNKS MERGE
#
# Everything between this banner and the closing banner is commented out
# because `../modules/{identity,network,compute,edge,ci-runner}` are built by
# chunks F3, F4 and F5 and are absent from this branch. Input names below are
# copied from CONTRACT.md §4 and are frozen; if a sibling module's real inputs
# disagree with these, the module is wrong, not this file — raise it with the
# orchestrator rather than editing either side unilaterally.
#
# Uncomment in the order given in WIRING.md. The order matters: identity
# produces the service account emails that network and compute consume, and
# compute produces the instance group that edge consumes.
# ════════════════════════════════════════════════════════════════════════════

# # ── 1. identity ── map-aware; NOT for_each'd. Produces the SA emails below.
# module "identity" {
#   source = "../modules/identity"
#
#   project_id        = var.project_id
#   project_number    = var.project_number
#   environment_keys  = module.env_contract.environment_keys
#   github_owner_id   = var.github_owner_id
#   github_repository = var.github_repository
#   github_allowed_ref = var.github_allowed_ref
# }
#
# # ── 2. network ── one VPC + subnet + NAT + firewall per environment.
# module "network" {
#   source   = "../modules/network"
#   for_each = module.env_contract.environments
#
#   project_id                    = var.project_id
#   environment_key               = each.value.environment_key
#   name_prefix                   = each.value.name_prefix
#   labels                        = each.value.labels
#   region                        = each.value.region
#   subnet_cidr                   = each.value.subnet_cidr
#   app_port                      = each.value.app_port
#   runtime_service_account_email = module.identity.runtime_service_account_emails[each.key]
#   nat_log_filter                = var.nat_log_filter
# }
#
# # ── 3. compute ── the private hardened VM, demo lanes only.
# module "compute" {
#   source   = "../modules/compute"
#   for_each = { for k, v in module.env_contract.environments : k => v if v.kind == "demo" }
#
#   project_id            = var.project_id
#   environment_key       = each.value.environment_key
#   name_prefix           = each.value.name_prefix
#   labels                = each.value.labels
#   zone                  = each.value.zone
#   machine_type          = each.value.machine_type
#   boot_disk_gb          = each.value.boot_disk_gb
#   subnet_self_link      = module.network[each.key].subnet_self_link
#   network_tag           = module.network[each.key].network_tag
#   service_account_email = module.identity.runtime_service_account_emails[each.key]
#   deletion_protection   = each.value.deletion_protect
#   startup_script_path   = var.startup_script_path
# }
#
# # ── 4. edge ── HTTPS LB, managed cert, Cloud Armor. Demo lanes only; a CI
# # lane has no public edge by design, which is why this filters on kind.
# module "edge" {
#   source   = "../modules/edge"
#   for_each = { for k, v in module.env_contract.environments : k => v if v.kind == "demo" }
#
#   project_id                      = var.project_id
#   environment_key                 = each.value.environment_key
#   name_prefix                     = each.value.name_prefix
#   labels                          = each.value.labels
#   hostname                        = each.value.hostname
#   dns_managed_zone                = var.dns_managed_zone
#   backend_instance_group          = module.compute[each.key].instance_group_self_link
#   app_port                        = each.value.app_port
#   allowed_ipv4                    = each.value.allowed_ipv4
#   allowed_ipv6                    = each.value.allowed_ipv6
#   rate_limit_threshold_per_minute = var.rate_limit_threshold_per_minute
#   enable_cdn                      = var.enable_cdn
# }
#
# # ── 5. ci-runner ── CI lanes only.
# module "ci_runner" {
#   source   = "../modules/ci-runner"
#   for_each = { for k, v in module.env_contract.environments : k => v if v.kind == "ci" }
#
#   project_id            = var.project_id
#   environment_key       = each.value.environment_key
#   name_prefix           = each.value.name_prefix
#   labels                = each.value.labels
#   zone                  = each.value.zone
#   machine_type          = each.value.machine_type
#   boot_disk_gb          = each.value.boot_disk_gb
#   subnet_self_link      = module.network[each.key].subnet_self_link
#   network_tag           = module.network[each.key].network_tag
#   service_account_email = module.identity.runtime_service_account_emails[each.key]
#   idle_suspend_minutes  = var.ci_idle_suspend_minutes
# }

# ════════════════════════════════════════════════════════════════════════════
# END INTEGRATION BLOCK
# ════════════════════════════════════════════════════════════════════════════
