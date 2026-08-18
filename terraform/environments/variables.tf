# Root inputs for the per-environment apply.
#
# ─── Why this file contains variable blocks and nothing else ────────────────
#
# `test/terraform-environment-keys.bats` copies this file verbatim into a
# throwaway, provider-free root so it can execute the validation rules with no
# network and no credentials. That only works while the file has no resource,
# no provider, no module call, and no local. Keep it that way — adding a
# `locals` block here would not break Terraform, but it would break the only
# test in the tree that can actually run these rules rather than grep for them.
#
# ─── Why `environments` is declared here as well as in the module ───────────
#
# The eleven contract rules live in `modules/env-contract` and are evaluated
# when this root passes the map into that module, which is a plan-time gate and
# is fail-closed. What the module cannot express is a rule about *this root*
# being a mutating one, so ENV-RULE-12-NON-EMPTY lives here: applying an empty
# map is a no-op in the module and a "destroy everything" plan here.
# The rules are deliberately not duplicated — one owner per rule.

variable "project_id" {
  description = "GCP project ID that owns every environment. Required; there is no safe default."
  type        = string

  validation {
    condition = (
      length(var.project_id) >= 6
      && !can(regex("(?i)changeme", var.project_id))
      && !can(regex("(?i)example", var.project_id))
    )
    error_message = "PROJECT-RULE-01-PLACEHOLDER: project_id looks like an unedited placeholder (empty, shorter than 6 characters, or containing \"CHANGEME\"/\"example\"). Copy a .tfvars.example, then replace it."
  }

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "PROJECT-RULE-02-FORMAT: project_id must be a valid GCP project ID: 6-30 characters, lowercase letters, digits and hyphens, starting with a letter and not ending with a hyphen."
  }
}

variable "project_number" {
  description = "Numeric GCP project number, used by the identity module for workload identity pool paths. \"\" defers it to integration."
  type        = string
  default     = ""

  validation {
    condition     = var.project_number == "" || can(regex("^[0-9]{6,}$", var.project_number))
    error_message = "PROJECT-RULE-03-NUMBER: project_number must be all digits (or \"\" to leave it unset)."
  }
}

variable "default_region" {
  description = "Region for the provider's default. Per-environment resources use their own entry's region; this only sets the provider fallback."
  type        = string
  default     = "europe-west2"
}

variable "environments" {
  description = "Typed map of every Signal Loom environment, keyed by stable environment key. The eleven contract rules are enforced by modules/env-contract; this root adds only the non-empty rule."
  type = map(object({
    kind             = string # "demo" | "ci"
    subnet_cidr      = string # RFC1918 /24, unique across the map
    region           = string # e.g. "europe-west2"
    zone             = string # e.g. "europe-west2-a"
    machine_type     = string # e.g. "n2-standard-16"
    boot_disk_gb     = number
    hostname         = string       # fully-qualified, unique across the map; "" disables DNS
    allowed_ipv4     = list(string) # CIDRs permitted at the edge; never 0.0.0.0/0
    allowed_ipv6     = list(string) # CIDRs permitted at the edge; never ::/0
    app_port         = number       # backend port the LB health-checks and forwards to
    deletion_protect = bool
    labels           = map(string) # extra labels, merged over the mandatory set
  }))

  # Rule 12 — a mutating root refuses an empty map.
  validation {
    condition     = length(var.environments) > 0
    error_message = "ENV-RULE-12-NON-EMPTY: environments must contain at least one entry. An empty map in a mutating root plans the destruction of everything currently in state; if that is what you want, say so explicitly with `terraform destroy`."
  }
}

variable "target_env" {
  description = "The single environment key this root is being applied to. Must be a key present in `environments`. Required; there is no safe default. See CONTRACT.md §5a."
  type        = string

  # Rule 13 — target_env names a key that actually exists.
  #
  # ─── Why this rule is the load-bearing one in this file ─────────────────────
  #
  # Environment identity is carried in two independent places: the backend
  # prefix chosen at `terraform init`, and the map key chosen at `terraform
  # apply`. Nothing in Terraform makes them agree. `init` against
  # osramp/environments/demo-1 followed by `apply -var-file=demo-2.tfvars`
  # raises no objection at all — a changed backend config is only detected when
  # `init` is re-run, and plan/apply silently reuse the cached .terraform/
  # backend pointer. The result is demo-2's resources written into demo-1's
  # state, or a plan reading "destroy demo-1, create demo-2" against demo-1's
  # state file. Both are silent, and both are plausible at the end of a long day.
  #
  # `target_env` collapses the second source of identity into one explicit,
  # reviewable value. It does not by itself make the two agree — that needs the
  # per-environment TF_DATA_DIR and the post-init prefix assertion, which belong
  # to the Makefile chunk (CONTRACT.md §5a mechanisms 2 and 3, tracked in
  # NOTES.md). What it does is make the value assertable at all: `terraform
  # output -raw target_env` is what Make compares against $(ENV) and against the
  # prefix it read back from state.
  #
  # ─── Why the existence check is not optional ────────────────────────────────
  #
  # Without it, a typo'd target_env produces a for_each over an empty map, which
  # is a *successful* plan proposing the destruction of every resource in the
  # current state — the exact outcome the variable exists to prevent, reached by
  # a different road. A zero-resource plan must never be reachable by typo.
  validation {
    condition = contains(keys(var.environments), var.target_env)
    error_message = format(
      "ENV-RULE-13-TARGET-ENV-EXISTS: target_env %q is not a key in the environments map (known keys: %s). A target_env that names nothing produces a zero-resource plan, which against a populated state means \"destroy everything\".",
      var.target_env,
      join(", ", sort(keys(var.environments))),
    )
  }
}

variable "dns_managed_zone" {
  description = "Name of the pre-existing Cloud DNS managed zone the edge module writes records into. \"\" disables DNS record creation for every environment."
  type        = string
  default     = ""
}

variable "nat_log_filter" {
  description = "Cloud NAT log filter passed to modules/network."
  type        = string
  default     = "ERRORS_ONLY"

  validation {
    condition     = contains(["ERRORS_ONLY", "TRANSLATIONS_ONLY", "ALL"], var.nat_log_filter)
    error_message = "NAT-RULE-01-LOG-FILTER: nat_log_filter must be ERRORS_ONLY, TRANSLATIONS_ONLY or ALL."
  }
}

variable "startup_script_path" {
  description = "Path to the VM startup script, relative to the compute module. Passed through to modules/compute."
  type        = string
  default     = "startup.sh"
}

variable "rate_limit_threshold_per_minute" {
  description = "Cloud Armor per-client request threshold passed to modules/edge."
  type        = number
  default     = 600

  validation {
    condition     = var.rate_limit_threshold_per_minute > 0
    error_message = "EDGE-RULE-01-RATE-LIMIT: rate_limit_threshold_per_minute must be greater than zero; a threshold of zero is an unrate-limited edge wearing a rate limit's name."
  }
}

variable "enable_cdn" {
  description = "Whether the edge backend service enables Cloud CDN."
  type        = bool
  default     = false
}

variable "ci_idle_suspend_minutes" {
  description = "Idle minutes before a ci-* lane suspends itself. Passed to modules/ci-runner."
  type        = number
  default     = 30

  validation {
    condition     = var.ci_idle_suspend_minutes > 0
    error_message = "CI-RULE-01-IDLE-SUSPEND: ci_idle_suspend_minutes must be greater than zero, or the lane never suspends and the estate bills forever."
  }
}

variable "github_owner_id" {
  description = "Numeric GitHub owner ID pinned in the workload identity provider's claim mapping. \"\" defers it to integration."
  type        = string
  default     = ""
}

variable "github_repository" {
  description = "GitHub repository in owner/repo form, pinned in the workload identity provider's claim mapping."
  type        = string
  default     = ""
}

variable "github_allowed_ref" {
  description = "Single git ref permitted to assume the CI service accounts, e.g. refs/heads/main."
  type        = string
  default     = ""
}
