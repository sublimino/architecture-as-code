variable "project_id" {
  description = "GCP project that owns the instance and its instance group."
  type        = string
}

variable "environment_key" {
  description = "Stable environment key, e.g. \"demo-1\" or \"ci-1\". Recorded on the instance as metadata so an operator on the box can tell which environment they are in."
  type        = string
}

variable "name_prefix" {
  description = "Deterministic resource-name prefix supplied by the env-contract module, e.g. \"sl-demo-1\"."
  type        = string
}

variable "labels" {
  description = "Mandatory label set merged by the env-contract module, applied to the instance."
  type        = map(string)
}

variable "zone" {
  description = "Zone for the instance and its unmanaged instance group."
  type        = string
}

variable "machine_type" {
  description = "Instance machine type. The demo runs a full Kind cluster plus the Signal Loom stack, which is why the estate's default is a 16-vCPU n2; smaller types will schedule but the acceptance suite times out on them."
  type        = string
  default     = "n2-standard-16"

  # ─── Why this module may assume "demo" without being told ─────────────────
  #
  # The environment object type is frozen (CONTRACT.md §3) and carries no field
  # this module could read to learn its own `kind`. It does not need one: the
  # environment root instantiates modules/compute under
  # `if v.kind == "demo"` and CI lanes go to modules/ci-runner instead, so
  # every instance this module ever plans is a demo lane. The floor below is
  # therefore a demo-lane floor by construction rather than by a conditional.
  #
  # ─── Where 8 comes from, and what it is not ───────────────────────────────
  #
  # The MEASURED profile for this workload is v1's CI VM: n2-standard-16,
  # 16 vCPU / 64GB, running the same `make demo-signalloom-up` bring-up
  # (scripts/ci/gcp-ci.sh). That is the default above and it is the only size
  # anything has been observed to complete on.
  #
  # 8 is not a second known-good value. It is the boundary below which the
  # answer is definitely no: the previous demo default of e2-standard-4 was a
  # guess made against nothing, and half of v1's measured vCPU count is the
  # most generous floor that still refuses it. An operator trialling
  # n2-standard-8 is making an experiment; an operator on e2-standard-4 has
  # made a mistake, and this rule is what tells them so at plan time rather
  # than at minute forty of a timing-out acceptance run.
  #
  # `try(..., 0)` rather than `can(...) && ...`: HCL's `&&` evaluates both
  # operands, so a regex that does not match would raise an error from the
  # `tonumber` side before the guard could suppress it. A non-matching type —
  # `e2-micro`, `f1-micro`, anything shared-core — yields 0 and is rejected,
  # which is the correct answer for all of them.
  validation {
    condition = try(
      tonumber(regex("^[a-z0-9]+-(?:standard|highmem|highcpu|custom)-([0-9]+)(?:-|$)", var.machine_type)[0]),
      0,
    ) >= 8
    error_message = "COMPUTE-RULE-01-MACHINE-TYPE-VCPU: machine_type must name at least 8 vCPUs. The demo VM runs a full Kind cluster plus the Signal Loom estate; the measured profile is n2-standard-16 (16 vCPU / 64GB, the same size v1 CI runs this bring-up on). Shared-core types (e2-micro, f1-micro) and anything below 8 vCPU are rejected because the acceptance suite times out on them, which reads as a broken demo rather than an undersized VM."
  }

  # The second half of the sizing question, which the vCPU count alone cannot
  # answer. n2-highcpu-16 satisfies the rule above and carries 16GB of RAM —
  # LESS than the e2-standard-4 this profile exists to replace, and a quarter
  # of the measured 64GB. Class is the only part of memory that a predefined
  # machine-type NAME exposes, so it is the only part that can be checked here.
  #
  # Stated plainly because the comment must not overclaim: a custom type
  # (`n2-custom-8-8192`) passes both rules with 8GB of RAM. Memory for custom
  # types is not derivable from the name and is not checked anywhere. That is a
  # known hole, left open rather than papered over with a rule that would only
  # appear to close it.
  validation {
    condition     = !can(regex("^[a-z0-9]+-highcpu-", var.machine_type))
    error_message = "COMPUTE-RULE-02-MACHINE-TYPE-CLASS: machine_type must not be a highcpu type. highcpu carries 1GB per vCPU, so n2-highcpu-16 has 16GB — less memory than the e2-standard-4 this profile replaces, and a quarter of the measured 64GB. Use a standard or highmem type."
  }
}

variable "boot_disk_gb" {
  description = "Boot disk size in GB. The demo estate's container images need roughly 100GB; the default of 200 is v1 CI's measured size and leaves headroom for a second build."
  type        = number
  default     = 200

  # Raised from 20 to 100. The old floor contradicted the description directly
  # above it — "container images need roughly 100GB" guarded by a rule that
  # accepted 20 — which is the shape of comment this repo treats as a defect in
  # its own right: an invariant asserted in prose and not enforced in code.
  # 100 is the documented requirement; 200 is what v1 CI actually provisions
  # (scripts/ci/gcp-ci.sh, BOOT_DISK_SIZE="200GB") and what the default sets.
  # A disk that fills mid-run fails as image-pull errors scattered across
  # unrelated pods, which is a genuinely expensive thing to diagnose.
  validation {
    condition     = var.boot_disk_gb >= 100
    error_message = "COMPUTE-RULE-03-BOOT-DISK: boot_disk_gb must be at least 100. The demo estate's container images alone need roughly that; v1 CI provisions 200GB for the identical bring-up. Below the floor the disk fills mid-run and surfaces as image-pull failures in unrelated pods."
  }
}

variable "boot_disk_type" {
  description = "Boot disk type. pd-balanced is the cost/throughput default; pd-ssd is worth it if image pulls dominate the run."
  type        = string
  default     = "pd-balanced"

  validation {
    condition     = contains(["pd-standard", "pd-balanced", "pd-ssd"], var.boot_disk_type)
    error_message = "boot_disk_type must be one of pd-standard, pd-balanced, pd-ssd."
  }
}

variable "subnet_self_link" {
  description = "Self-link of the subnet to attach to, from the network module."
  type        = string
}

variable "network_tag" {
  description = "Network tag from the network module, derived from the environment key."
  type        = string
}

variable "service_account_email" {
  description = "Per-environment runtime service account, supplied by the identity module. Never the default compute service account — that one carries project-wide editor in most projects."
  type        = string

  validation {
    condition     = !endswith(var.service_account_email, "-compute@developer.gserviceaccount.com")
    error_message = "service_account_email must not be the default compute service account (<project-number>-compute@developer.gserviceaccount.com); supply a per-environment service account from modules/identity."
  }

  validation {
    condition     = length(trimspace(var.service_account_email)) > 0
    error_message = "service_account_email must be set; an empty value makes GCP attach the default compute service account."
  }
}

variable "deletion_protection" {
  description = "Instance deletion protection. The roots pass true for demo environments and false for ci environments, which are meant to be disposable."
  type        = bool
}

variable "app_port" {
  description = "Backend port the load balancer forwards to. Becomes the instance group's named port, which the edge module's backend service resolves."
  type        = number

  validation {
    condition     = var.app_port >= 1 && var.app_port <= 65535
    error_message = "app_port must be between 1 and 65535."
  }
}

variable "startup_script_path" {
  description = "Path to the startup script. Defaults to the module's own version-controlled script at startup/demo-vm.sh when left empty."
  type        = string
  default     = ""
}

# ── Why Ubuntu 24.04 and not Debian 12 ──────────────────────────────────────
#
# This default was debian-12, and the divergence from v1 CI — which has run the
# Signal Loom bring-up on ubuntu-2404-lts since the pipeline existed — cost a
# full day of cascading, individually plausible failures on 2026-08-18. Every
# one of them traced back here:
#
#   * Debian 12 ships skopeo 1.9.3, which speaks Docker API 1.22. Docker 29
#     requires >= 1.40, so scripts/build-sign-dashboard.sh died with
#     "client version 1.22 is too old". The FIRST presentation of that fault
#     was "writing blob: io: read/write on closed pipe", which names neither
#     skopeo nor the API version and reads like a broken pipe under load.
#   * Docker installed fresh from download.docker.com onto Debian 12 enables
#     the containerd image store. Under it `kind load` EXITS 0 HAVING
#     TRANSFERRED NOTHING — the failure mode scripts/kind-load-verified.sh was
#     written to catch, documented in Makefile:297 as "fatal on every cold
#     run". Turning the store off restores kind load and then breaks the
#     dashboard build instead: "Attestation is not supported for the docker
#     driver". There is no setting of that one flag under which both halves of
#     this repo work on Debian 12.
#
# So the image family is not a cosmetic preference and must not be "tidied"
# back to a Debian default. It is the single variable that keeps this VM's
# toolchain in the configuration the estate has actually been tested in.
# Changing it forces instance replacement, which is cheap here and is the
# point: the VM is disposable, the estate is not.
variable "image_family" {
  description = "Boot image family. Defaults to ubuntu-2404-lts to match the v1 CI environment the Signal Loom bring-up is tested in; see the comment above before changing it."
  type        = string
  default     = "ubuntu-2404-lts-amd64"
}

variable "image_project" {
  description = "Project publishing the boot image family."
  type        = string
  default     = "ubuntu-os-cloud"
}

variable "enable_confidential_compute" {
  description = "Enable AMD SEV Confidential Computing. Defaults false because it constrains the instance to the N2D/C2D families and forces on_host_maintenance = TERMINATE, and the demo's default n2-standard-16 does not support it. Set true only together with a compatible machine_type such as n2d-standard-16."
  type        = bool
  default     = false
}
