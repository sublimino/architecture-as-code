variable "project_id" {
  description = "GCP project that owns the instance and its instance group."
  type        = string
}

variable "environment_key" {
  description = "Stable environment key, e.g. \"demo-1\" or \"ci-1\". Recorded on the instance as metadata so an operator on the box can tell which environment they are in."
  type        = string
}

# ---------------------------------------------------------------------------
# Lane kind — the input that decides whether this VM is reapable
# ---------------------------------------------------------------------------
#
# NO DEFAULT, deliberately, and this is the single most consequential decision
# in the module's interface.
#
# A default of "demo" fails open in the expensive direction: a CI lane whose
# caller forgot to pass `kind` would plan and apply perfectly, carry no
# `ci-lane` label, and be invisible to scripts/ci/gcp-tf-reaper.sh forever. The
# reaper would report "0 suspended" and be telling the truth. Nothing anywhere
# would error, and the only signal would be the invoice.
#
# A default of "ci" fails open in the other direction, which is worse: a demo VM
# would acquire the label the reaper selects on.
#
# So there is no safe default, and the correct answer is to make the caller say
# which one it is. `kind` is already a field of the frozen environment object
# (CONTRACT §3), so the root has the value to hand — this adds no new concept,
# it just stops the module guessing.
variable "kind" {
  description = "Lane kind from the environment contract: \"demo\" or \"ci\". Decides whether the instance carries the `ci-lane` label that scripts/ci/gcp-tf-reaper.sh selects on, and whether it publishes an idle-suspend budget. No default — see the argument in variables.tf."
  type        = string

  validation {
    condition     = contains(["demo", "ci"], var.kind)
    error_message = "COMPUTE-RULE-13-KIND: kind must be \"demo\" or \"ci\". It decides whether this instance carries the `ci-lane` label that scripts/ci/gcp-tf-reaper.sh selects on to SUSPEND instances, so an unrecognised value must fail the plan rather than resolve to a guess."
  }
}

# ---------------------------------------------------------------------------
# The idle budget, published on CI lanes only
# ---------------------------------------------------------------------------
#
# Migrated from modules/ci-runner, with one change: the default is 0 rather than
# 45, and 0 means "not a reapable lane".
#
# That inversion is what keeps a demo lane's instance metadata BYTE-IDENTICAL to
# what it was before this module learned about CI lanes. A demo VM must not
# publish an idle-suspend budget at all — not 0, not 45 — because the metadata
# key's presence is a signal the reaper and any future operator tooling will
# read, and a demo VM advertising an idle budget invites exactly the mistake the
# whole label design exists to prevent.
#
# The floor of 5 is enforced where it can see the lane kind: a `precondition` on
# the instance, not a `validation` here, because a validation cannot know that 0
# is legal for a demo lane and fatal for a CI one.
variable "idle_suspend_minutes" {
  description = "Idle minutes after which scripts/ci/gcp-tf-reaper.sh may suspend this lane, published as instance metadata so the reaper reads the budget off the instance rather than carrying a duplicate constant. Only consulted when kind is \"ci\"; 0 (the default) means the metadata key is not emitted at all, which is what a demo lane must look like. A CI lane is required by precondition to pass at least 5."
  type        = number
  default     = 0

  validation {
    condition     = var.idle_suspend_minutes == 0 || var.idle_suspend_minutes >= 5
    error_message = "COMPUTE-RULE-14-IDLE-SUSPEND: idle_suspend_minutes must be 0 (disabled — the demo-lane answer) or at least 5. A value between 1 and 4 suspends CI lanes mid-run, and the run's failure presents as a lost SSH session rather than as a reaper that fired too early."
  }
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

  # ─── The floor applies to BOTH lane kinds, and that is the point ──────────
  #
  # This paragraph used to read "why this module may assume demo without being
  # told": the root filtered `if v.kind == "demo"` and CI lanes went to
  # modules/ci-runner, so every instance here was a demo lane by construction.
  # That module is gone and the filter is gone with it, so the assumption is no
  # longer available — and it turns out it was never wanted.
  #
  # A CI lane exists to run the DEMO bring-up. Sizing it below the demo floor
  # would make a CI failure ambiguous between a real defect and an undersized
  # box, which costs more than the machine. modules/ci-runner had no vCPU floor
  # at all and its tfvars example carried the same n2-standard-16 anyway — the
  # rule below is what makes that agreement enforced instead of coincidental.
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

# ---------------------------------------------------------------------------
# Tailscale
#
# A tailnet node ON the demo VM, so the estate is reachable from Andy's own
# devices without the IAP tunnel dance. It is off by default and every resource
# it needs is gated on the flag, because the secret holding the auth key is
# created out of band and an environment that does not have one must still plan
# and apply cleanly.
#
# What it deliberately does NOT change: there is still no external IP, still no
# ingress rule beyond IAP, and still no widened source range. Tailscale is an
# outbound-only protocol — the node dials the coordination server and its peers,
# and nothing dials in — which is the entire reason it fits an estate whose
# posture story is "no inbound path exists to attack".
# ---------------------------------------------------------------------------

variable "tailscale_enabled" {
  description = "Install Tailscale on the VM and grant its runtime service account read access to the auth-key secret. Defaults false: the secret is created out of band, so an environment without one must still plan and apply. With this false no Tailscale resource is planned, no metadata key is emitted, and the startup script's Tailscale stage does not run."
  type        = bool
  default     = false
}

variable "tailscale_authkey_secret_id" {
  description = "Secret Manager secret id (the short id, not the full resource name) holding a reusable, ephemeral, pre-approved Tailscale auth key. Read at RUNTIME by the VM under its own attached service account; never placed in instance metadata, which is stored in plain text. Only consulted when tailscale_enabled is true."
  type        = string
  default     = "sl-demo-tailscale-authkey"

  # A short id, not a full resource path. `projects/x/secrets/y` is what the
  # data source RETURNS and what the IAM binding consumes; passing that form in
  # produces `projects/x/secrets/projects/x/secrets/y`, which fails at plan with
  # a "not found" that reads as a missing secret rather than a malformed input.
  # GCP's own constraint is the same character class, capped at 255.
  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{1,255}$", var.tailscale_authkey_secret_id))
    error_message = "COMPUTE-RULE-04-SECRET-ID: tailscale_authkey_secret_id must be a bare Secret Manager secret id — letters, digits, underscores and hyphens, 1 to 255 characters. A full resource path (\"projects/<p>/secrets/<s>\") is not accepted: the data source returns that form and the IAM binding consumes it, so passing it in produces a doubled path and a \"secret not found\" error that reads as a missing secret rather than a malformed input."
  }
}

variable "tailscale_tag" {
  description = "ACL tag applied to this node at `tailscale up --advertise-tags`. A tagged node is owned by the tailnet policy rather than by the user whose auth key created it, which is what makes the node's access reviewable in the ACL file and survivable when that user leaves."
  type        = string
  default     = "tag:sl-demo"

  # `tag:` prefix enforced rather than assumed. Tailscale rejects an
  # unprefixed value at `tailscale up`, and the rejection happens on the VM at
  # boot with the message going to the serial console — where nobody is looking,
  # because the symptom is "the node never appeared in the tailnet", which reads
  # as a missing auth key or a firewall problem. Failing at plan costs one line
  # and closes a genuinely expensive misdiagnosis.
  validation {
    condition     = can(regex("^tag:[a-z0-9][a-z0-9-]*$", var.tailscale_tag))
    error_message = "COMPUTE-RULE-05-TAILSCALE-TAG: tailscale_tag must be a Tailscale ACL tag of the form \"tag:<name>\", lowercase, starting with a letter or digit. Tailscale refuses an unprefixed value at `tailscale up`, and it refuses it on the VM at boot with the message going to the serial console — so the observed symptom is a node that never joins the tailnet, which reads as a bad auth key rather than as a malformed tag."
  }
}

variable "tailscale_ssh_enabled" {
  description = "Pass --ssh to `tailscale up`, letting tailnet principals SSH to this VM with authorisation decided by the tailnet ACL. Defaults FALSE; see the argument in variables.tf before enabling."
  type        = bool
  default     = false

  # ─── The argument, both ways, because the brief asked for one ─────────────
  #
  # FOR: Tailscale SSH is genuinely good. It needs no key distribution, no
  # sshd configuration and no port open anywhere; authorisation is a rule in the
  # tailnet ACL evaluated per connection; sessions can be recorded centrally; and
  # it removes the last reason to keep an IAP tunnel open at all. On a box Andy
  # reaches from four devices, it is the ergonomic answer.
  #
  # AGAINST, and why it wins here: this VM's whole posture claim is that there
  # is exactly ONE identity-gated way in, and that the gate is Google IAM — IAP
  # authorises the tunnel against roles/iap.tunnelResourceAccessor, and OS Login
  # authorises the login against IAM. Enabling Tailscale SSH adds a SECOND
  # authorisation system that IAM cannot see: a principal denied by OS Login can
  # still be admitted by the tailnet ACL, and nothing in the GCP audit log or in
  # `gcloud compute instances describe` says so. For an estate whose subject IS
  # the posture, an access path invisible to the cloud's own audit surface is a
  # bad default even when the path itself is well built.
  #
  # It is a default, not a prohibition. Set true in a tfvars, in a diff someone
  # reads, and the trade is made deliberately with a name attached — which is
  # the same rule every other widening in this tree follows.
  #
  # Note the asymmetry that makes false cheap: with SSH off, Andy still reaches
  # the VM's app port over the tailnet directly, which is the thing he actually
  # asked for. Only the shell falls back to IAP, and IAP for a shell already
  # works today.
}

variable "enable_confidential_compute" {
  description = "Enable AMD SEV Confidential Computing. Defaults false because it constrains the instance to the N2D/C2D families and forces on_host_maintenance = TERMINATE, and the demo's default n2-standard-16 does not support it. Set true only together with a compatible machine_type such as n2d-standard-16."
  type        = bool
  default     = false
}
