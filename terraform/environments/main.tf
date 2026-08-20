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
# module call is a single `for_each` over `local.target_environments`,
# and each reads `each.value.<input>`. Adding `demo-2` is therefore one new
# entry in a tfvars map and zero `.tf` edits. `demo-1-and-demo-2.tfvars.example`
# is the worked proof, and the bats suite asserts it byte-for-byte differs from
# the single-environment example only inside the tfvars file.

# The platform root owns the project-level singletons (CONTRACT §5b): the
# runtime service accounts, the WIF pool, the audit sink. This root CONSUMES
# them read-only. Declaring them here instead would place them in an
# ENVIRONMENT's state, where `make gcp-tf-destroy ENV=demo-1` destroys
# everything — taking CI's ability to authenticate with it.
data "terraform_remote_state" "platform" {
  backend = "gcs"

  config = {
    bucket = var.state_bucket_name
    prefix = "osramp/platform"
  }
}

module "env_contract" {
  source = "../modules/env-contract"

  environments = var.environments
}

# ─── The single-environment filter (CONTRACT.md §5a mechanism 1) ─────────────
#
# The whole map goes into `module.env_contract` so that the cross-environment
# validations — unique hostnames, unique subnets — still bite; they cannot
# detect a collision between demo-1 and demo-2 if only one of them is in scope.
# Resources are then instantiated for exactly one key.
#
# The filter reads the module's *resolved* map rather than `var.environments`
# directly, because the resolved map is what carries name_prefix and the merged
# label set. The key set is identical by construction (the resolved map is a
# projection of var.environments over the same keys), so the filter selects the
# same single entry the contract specifies. Recorded in NOTES.md.
#
# `var.target_env` is validated to be a key of `var.environments`, so this
# expression yields exactly one element — never zero. That matters: an empty
# for_each is a *successful* plan that proposes destroying everything already
# in state, which is precisely the accident target_env exists to prevent.
locals {
  target_environments = {
    for k, v in module.env_contract.environments : k => v if k == var.target_env
  }
}

# ─── The single definition of "which lanes have an edge" ───────────────────
#
# This map is the ONE definition of "which lanes have an edge". The live
# `module "network"` block below reads it through `edge_enabled`, and the
# commented `module "edge"` block reads the same map through its `for_each`
# when it is re-enabled, so "the load balancer exists" and "the health-check
# ingress exists" cannot disagree.
#
# Today the map is literally empty because the edge module block is commented
# out, so no lane has a live HTTPS load balancer. Any non-empty expression here
# would describe an intention rather than a fact, which is how a review ends up
# claiming a web edge exists when nothing in GCP actually serves it.
#
# Re-enabling the edge is therefore a deliberate TWO-line change:
#   1. uncomment the `module "edge"` block below; and
#   2. replace `{}` here with
#      `{ for k, v in local.target_environments : k => v if v.kind == "demo" }`
#
# Both halves are guarded. Doing one without the other turns a test red rather
# than silently reintroducing a public HTTPS frontend: test/terraform-edge-
# dormant.bats asserts the module graph contains no edge module, and
# terraform/environments/tests/edge_dormant.tftest.hcl asserts this map stays
# empty and that no lane gains the health-check ingress that only an edge
# should need.
locals {
  edge_environments = {}
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
    access_mode                     = var.access_mode
    iap_members                     = var.iap_members
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

# ─── The effective access path, not the wished-for one ──────────────────────
#
# `var.access_mode` describes the posture of the WEB edge: Identity-Aware Proxy
# in front of an HTTPS load balancer. With no edge instantiated there is no web
# front door for it to describe, so reporting "iap" tells a reader the estate
# has a control it does not have. The path actually in force is the IAP TCP
# tunnel — roles/iap.tunnelResourceAccessor, source range 35.235.240.0/20,
# ports 22 and app_port — which is a different and narrower thing.
#
# When the edge comes back, the same local resolves to var.access_mode again
# automatically because the lane key appears in local.edge_environments.
locals {
  effective_access_mode = contains(keys(local.edge_environments), var.target_env) ? var.access_mode : "iap_tunnel"
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

# # ── 1. identity ── DO NOT INSTANTIATE THIS MODULE IN THIS ROOT.
# #
# # This block used to live here, uncommented by the WIRING instructions, and it
# # was a reversibility hole that an adversarial review found. The reasoning that
# # put it here was sound as far as it went: the WIF pool and the CI service
# # accounts are project-level singletons, so they must not be filtered by
# # target_env or applying demo-1 would delete demo-2's service account.
# #
# # The conclusion was wrong. Declaring a singleton in THIS root puts it in an
# # ENVIRONMENT's state file, and `make gcp-tf-destroy ENV=demo-1` destroys
# # everything in that state. The destroy guard refuses the `platform` and
# # `bootstrap` roots by path, so it would have permitted exactly this — taking
# # the workload identity pool, both CI service accounts and every project IAM
# # member with it. CI could then no longer authenticate at all, and recovering
# # needs bootstrap-level credentials. The target's own closing message claims
# # the platform singletons were not touched; it would have been lying.
# #
# # Singletons belong to terraform/platform (CONTRACT §5b). This root CONSUMES
# # them read-only:
# #
# #   data "terraform_remote_state" "platform" {
# #     backend = "gcs"
# #     config = {
# #       bucket = var.state_bucket_name
# #       prefix = "osramp/platform"
# #     }
# #   }
# #
# # The module blocks below have already been rewritten to read
# #   data.terraform_remote_state.platform.outputs.runtime_service_account_emails[each.key]
# # in place of the module output they previously consumed.
# #
# # test/terraform-identity.bats asserts this root declares no identity module.
#
# ── 2. network ── one VPC + subnet + NAT + firewall, for the target env only.
module "network" {
  source   = "../modules/network"
  for_each = local.target_environments

  project_id                    = var.project_id
  environment_key               = each.value.environment_key
  name_prefix                   = each.value.name_prefix
  labels                        = each.value.labels
  region                        = each.value.region
  subnet_cidr                   = each.value.subnet_cidr
  app_port                      = each.value.app_port
  runtime_service_account_email = data.terraform_remote_state.platform.outputs.runtime_service_account_emails[each.key]
  nat_log_filter                = var.nat_log_filter

  # The GCP health-check firewall rule exists only for a lane that actually
  # has a load balancer, and both facts are derived from the one
  # local.edge_environments map above.
  edge_enabled = contains(keys(local.edge_environments), each.key)

  # Reviewed per-environment widening; see the tfvars for the rationale. The
  # ports travel with the destinations because opening a port and naming a
  # destination are halves of one decision — a reviewer looking at only one of
  # them cannot tell what was actually granted.
  egress_public_https_destinations = var.egress_public_https_destinations
  egress_public_ports              = var.egress_public_ports

  # UDP egress, both halves empty by default so no rule is created. Ports and
  # destinations travel together for the same reason the TCP pair does: opening
  # a port and naming a destination are halves of one decision, and a reviewer
  # looking at only one of them cannot tell what was actually granted.
  egress_public_udp_ports        = var.egress_public_udp_ports
  egress_public_udp_destinations = var.egress_public_udp_destinations
}

# ── 3. compute ── the private hardened VM. EVERY lane, demo and CI alike.
#
# ─── Why this `for_each` is no longer filtered on kind ──────────────────────
#
# It used to read `if v.kind == "demo"`, and CI lanes were built by
# `module "ci_runner"` from a second module. Andy's decision (2026-08-20) is
# that a CI environment should BE a demo environment, differing only in that it
# suspends itself when idle and carries a reaper label — so there is one module
# and one filter, which is no filter at all.
#
# What that fixes is not tidiness. The two modules had diverged in exactly the
# direction that hurts: modules/ci-runner had no `metadata_startup_script`, so a
# CI lane booted a bare Debian box and every fix to the demo bring-up landed on
# a machine CI never ran. CI was green against something that was not the demo.
#
# THE FILTER'S REMOVAL IS ALSO A SAFETY EVENT, and it is worth naming here
# rather than only in the reaper. modules/ci-runner's instance name was
# `sl-<key>-runner` and scripts/ci/gcp-tf-reaper.sh matched exactly that shape;
# the name convention WAS the property stopping the reaper reaching a demo VM.
# Unified lanes are `sl-<key>-vm` for both kinds, so that gate would have
# matched nothing and the reaper would have suspended nothing while reporting
# success. The selector moved onto the `ci-lane` label — emitted by
# modules/compute for `kind = "ci"` and for nothing else — which is derived from
# this map rather than from a string convention. See the gate list at the head
# of scripts/ci/gcp-tf-reaper.sh.
module "compute" {
  source   = "../modules/compute"
  for_each = local.target_environments

  project_id            = var.project_id
  environment_key       = each.value.environment_key
  kind                  = each.value.kind
  name_prefix           = each.value.name_prefix
  labels                = each.value.labels
  zone                  = each.value.zone
  machine_type          = each.value.machine_type
  boot_disk_gb          = each.value.boot_disk_gb
  subnet_self_link      = module.network[each.key].subnet_self_link
  network_tag           = module.network[each.key].network_tag
  service_account_email = data.terraform_remote_state.platform.outputs.runtime_service_account_emails[each.key]
  deletion_protection   = each.value.deletion_protect
  startup_script_path   = var.startup_script_path

  # Published as instance metadata on CI lanes only; the module emits no key at
  # all for a demo lane, which is what keeps a demo VM's metadata identical to
  # what it was before this module served both kinds. The ternary is here rather
  # than in the module because the module's floor of 5 must not reject the demo
  # answer of 0, and a variable validation cannot see the lane kind.
  idle_suspend_minutes = each.value.kind == "ci" ? var.ci_idle_suspend_minutes : 0

  # The compute module health-checks and serves on this port, and the network
  # module opens the health-check firewall rule for exactly it. Passing the same
  # resolved value to both is what keeps them from drifting apart.
  app_port = each.value.app_port

  # Tailscale. Off by default; the auth-key secret is created out of band, so an
  # environment without one must still plan and apply. With the flag false the
  # module plans no data source, no IAM binding and no metadata key.
  tailscale_enabled           = var.tailscale_enabled
  tailscale_authkey_secret_id = var.tailscale_authkey_secret_id
  tailscale_tag               = var.tailscale_tag
  tailscale_ssh_enabled       = var.tailscale_ssh_enabled
}

# # ── 4. edge ── HTTPS LB, managed cert, Cloud Armor. Demo lanes only; a CI
# # lane has no public edge by design, which is why local.edge_environments
# # must switch from {} to the demo-lane filter at the same time this block is
# # uncommented.
# module "edge" {
#   source   = "../modules/edge"
#   for_each = local.edge_environments
#
#   project_id                      = var.project_id
#   environment_key                 = each.value.environment_key
#   name_prefix                     = each.value.name_prefix
#   labels                          = each.value.labels
#   hostname                        = each.value.hostname
#   dns_managed_zone                = var.dns_managed_zone
#   access_mode                     = var.access_mode
#   iap_members                     = var.iap_members
#   backend_instance_group          = module.compute[each.key].instance_group_self_link
#   app_port                        = each.value.app_port
#   allowed_ipv4                    = each.value.allowed_ipv4
#   allowed_ipv6                    = each.value.allowed_ipv6
#   rate_limit_threshold_per_minute = var.rate_limit_threshold_per_minute
#   enable_cdn                      = var.enable_cdn
# }
#
# ── 5. ci-runner ── DELETED. There is no fifth module.
#
# `module "ci_runner"` stood here, commented, waiting for `../modules/ci-runner`
# to be wired up. Both are gone as of 2026-08-20: the module was absorbed into
# modules/compute and this block's job is done by the unfiltered `for_each` on
# module "compute" above.
#
# Recorded rather than silently deleted because the block's absence is now a
# TESTED property (test/terraform-ci-lifecycle.bats), and because the obvious
# repair for a future "CI lanes need something demo lanes do not" is to
# reintroduce it. Do not. The reason the split was removed is that a CI lane
# that is not the demo environment is a CI lane testing something the demo is
# not — and the observable symptom of that was CI booting a bare box with no
# `metadata_startup_script` at all. Add the difference to modules/compute behind
# `var.kind` instead.

# ════════════════════════════════════════════════════════════════════════════
# END INTEGRATION BLOCK
# ════════════════════════════════════════════════════════════════════════════
