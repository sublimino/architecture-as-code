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
}

variable "boot_disk_gb" {
  description = "Boot disk size in GB. Container images for the demo estate need roughly 100GB; the default leaves headroom for a second build."
  type        = number
  default     = 200

  validation {
    condition     = var.boot_disk_gb >= 20
    error_message = "boot_disk_gb must be at least 20; the base image plus the demo's container images will not fit below that."
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

variable "image_family" {
  description = "Boot image family."
  type        = string
  default     = "debian-12"
}

variable "image_project" {
  description = "Project publishing the boot image family."
  type        = string
  default     = "debian-cloud"
}

variable "enable_confidential_compute" {
  description = "Enable AMD SEV Confidential Computing. Defaults false because it constrains the instance to the N2D/C2D families and forces on_host_maintenance = TERMINATE, and the demo's default n2-standard-16 does not support it. Set true only together with a compatible machine_type such as n2d-standard-16."
  type        = bool
  default     = false
}
