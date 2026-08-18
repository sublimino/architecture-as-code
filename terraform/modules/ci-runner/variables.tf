variable "project_id" {
  description = "GCP project that owns the CI lane instance."
  type        = string
}

variable "environment_key" {
  description = <<-EOT
    The CI lane key, e.g. "ci-1". Restricted to CI keys by validation: this module builds
    disposable lanes with deletion_protection off, and pointing it at a demo environment
    would produce a demo VM that the reaper is entitled to suspend.
  EOT
  type        = string

  validation {
    condition     = can(regex("^ci-[1-9][0-9]*$", var.environment_key))
    error_message = "environment_key must be a CI lane key matching ^ci-[1-9][0-9]*$ — this module never builds demo environments."
  }
}

variable "name_prefix" {
  description = "Deterministic name prefix from the environment contract, e.g. sl-ci-1."
  type        = string
}

variable "labels" {
  description = "Mandatory label set from the environment contract. ci-lane is merged over the top."
  type        = map(string)
}

variable "zone" {
  description = "Zone for the lane instance."
  type        = string
}

variable "machine_type" {
  description = "Machine type for the lane instance."
  type        = string
}

variable "boot_disk_gb" {
  description = "Boot disk size in GB."
  type        = number

  validation {
    condition     = var.boot_disk_gb >= 20
    error_message = "boot_disk_gb must be at least 20."
  }
}

variable "subnet_self_link" {
  description = "Self link of the subnet the lane attaches to. No external address is ever configured."
  type        = string
}

variable "network_tag" {
  description = "Network tag the firewall rules key on."
  type        = string
}

variable "service_account_email" {
  description = <<-EOT
    Per-lane service account email, produced by modules/identity keyed on this lane's key.

    Required and non-empty on purpose. Omitting the service_account block entirely does not
    produce a VM with no identity — it produces one running as the default Compute Engine
    service account, which holds roles/editor on the whole project.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[^ @]+@[^ @]+$", var.service_account_email))
    error_message = "service_account_email must be a service account email; an empty value silently attaches the default Compute Engine SA, which holds roles/editor."
  }
}

variable "idle_suspend_minutes" {
  description = "Idle minutes after which scripts/ci/gcp-tf-reaper.sh may suspend this lane. Published as instance metadata so the reaper reads it from the instance rather than carrying a duplicate constant."
  type        = number
  default     = 45

  validation {
    condition     = var.idle_suspend_minutes >= 5
    error_message = "idle_suspend_minutes must be at least 5 — a shorter window suspends lanes mid-run."
  }
}

variable "boot_image" {
  description = "Boot image family for the lane."
  type        = string
  default     = "debian-cloud/debian-12"
}
