variable "project_id" {
  description = "GCP project ID that owns every edge resource. Explicit input; never derived, never defaulted to a real project."
  type        = string

  validation {
    condition     = length(trimspace(var.project_id)) > 0
    error_message = "project_id must be a non-empty project ID, e.g. \"CHANGEME-project\"."
  }
}

variable "environment_key" {
  description = "Stable environment key matching ^(demo|ci)-[1-9][0-9]*$. Appears in every resource name and in the DNS hostname."
  type        = string

  validation {
    condition     = can(regex("^(demo|ci)-[1-9][0-9]*$", var.environment_key))
    error_message = "environment_key must match ^(demo|ci)-[1-9][0-9]*$, e.g. \"demo-1\" or \"ci-2\"."
  }
}

variable "name_prefix" {
  description = "Deterministic, key-embedded resource name prefix supplied by the caller (\"sl-<environment_key>\"). Every resource in this module names itself \"<name_prefix>-<role>\"."
  type        = string

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", var.name_prefix)) && length(var.name_prefix) <= 50
    error_message = "name_prefix must be a valid GCP name fragment (lowercase RFC1035) of at most 50 characters, leaving room for the \"-<role>\" suffix within the 63-character GCP limit."
  }
}

variable "labels" {
  description = "Mandatory label set merged by the caller, applied to every edge resource that supports labels."
  type        = map(string)
}

variable "hostname" {
  description = "Fully-qualified public hostname for this environment. The empty string disables the ENTIRE public frontend: no certificate, no proxies, no forwarding rules, no DNS record. Fail closed, not half-created."
  type        = string
  default     = ""

  validation {
    condition     = var.hostname == "" || can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)+\\.?$", var.hostname))
    error_message = "hostname must be empty or a fully-qualified DNS name, e.g. \"demo-1.example.invalid\"."
  }
}

variable "dns_managed_zone" {
  description = "Name of the Cloud DNS managed zone that owns hostname. The empty string disables DNS record creation while leaving the load balancer intact."
  type        = string
  default     = ""
}

variable "backend_instance_group" {
  description = "Self-link of the unmanaged instance group wrapping the application VM (output instance_group_self_link of modules/compute)."
  type        = string
}

variable "app_port" {
  description = "Backend port the load balancer health-checks and forwards to. Must match the compute module's named port."
  type        = number

  validation {
    condition     = var.app_port >= 1 && var.app_port <= 65535 && floor(var.app_port) == var.app_port
    error_message = "app_port must be an integer between 1 and 65535."
  }
}

variable "allowed_ipv4" {
  description = "IPv4 CIDRs permitted at the edge. COARSE EXPOSURE CONTROL ONLY -- this is not authentication. Never 0.0.0.0/0. An empty list is legal and means the default deny is the only rule, which is the safe state."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.allowed_ipv4 : can(cidrnetmask(c))])
    error_message = "Every allowed_ipv4 entry must parse as an IPv4 CIDR, e.g. \"192.0.2.0/24\"."
  }

  # A literal `c != "0.0.0.0/0"` was the original rule, and an adversarial review
  # walked straight past it: ["0.0.0.0/1", "128.0.0.0/1"] covers every IPv4
  # address, parses as two valid CIDRs, fits inside the 500-entry cap, and gets
  # allow-listed at priority 1000 above the default deny. The error message
  # asserted a property the condition did not enforce.
  #
  # A prefix length is the honest expression of "not the internet". /8 still
  # permits 16.7M addresses, which is far wider than any demo needs, but it is a
  # ceiling a reviewer can reason about rather than a single blocked spelling.
  validation {
    condition = alltrue([
      for c in var.allowed_ipv4 : can(tonumber(split("/", c)[1])) && tonumber(split("/", c)[1]) >= 8
    ])
    error_message = "Every allowed_ipv4 entry must be /8 or narrower. 0.0.0.0/0 allows the internet; so does the pair 0.0.0.0/1 and 128.0.0.0/1, which is why this checks the prefix length rather than blocking one spelling."
  }

  validation {
    condition     = length(var.allowed_ipv4) <= 500
    error_message = "allowed_ipv4 is capped at 500 entries (50 chunks of 10) so that generated Cloud Armor rule priorities cannot collide with the next priority band."
  }
}

variable "allowed_ipv6" {
  description = "IPv6 CIDRs permitted at the edge. COARSE EXPOSURE CONTROL ONLY -- this is not authentication. Never ::/0."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.allowed_ipv6 : can(regex("^[0-9A-Fa-f:]+/[0-9]{1,3}$", c))])
    error_message = "Every allowed_ipv6 entry must parse as an IPv6 CIDR, e.g. \"2001:db8::/32\"."
  }

  # Same defect as allowed_ipv4, same fix. ["::/1", "8000::/1"] is the IPv6
  # spelling of the whole internet and passed a literal `!= "::/0"` compare.
  # The prior regex also accepted a /999 prefix, which tonumber now bounds.
  validation {
    condition = alltrue([
      for c in var.allowed_ipv6 :
      can(tonumber(split("/", c)[1])) && tonumber(split("/", c)[1]) >= 32 && tonumber(split("/", c)[1]) <= 128
    ])
    error_message = "Every allowed_ipv6 entry must have a prefix length between /32 and /128. ::/0 allows the internet; so does the pair ::/1 and 8000::/1, which is why this checks the prefix length rather than blocking one spelling."
  }

  validation {
    condition     = length(var.allowed_ipv6) <= 500
    error_message = "allowed_ipv6 is capped at 500 entries (50 chunks of 10) so that generated Cloud Armor rule priorities cannot collide with the next priority band."
  }
}

variable "rate_limit_threshold_per_minute" {
  description = "Requests per minute per client IP that an allowlisted source may make before Cloud Armor bans it. Must be finite and positive -- there is no \"unlimited\" value."
  type        = number
  default     = 600

  validation {
    condition     = var.rate_limit_threshold_per_minute > 0 && var.rate_limit_threshold_per_minute <= 10000 && floor(var.rate_limit_threshold_per_minute) == var.rate_limit_threshold_per_minute
    error_message = "rate_limit_threshold_per_minute must be a finite positive integer no greater than 10000."
  }
}

variable "enable_cdn" {
  description = "Enable Cloud CDN on the backend service. Defaults to false: a demo estate behind an allowlist gains nothing from caching and a cache in front of an authenticated app is a disclosure risk."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Additive inputs beyond CONTRACT.md section 4. Each has a safe default, so a
# caller passing only the contract inputs gets correct behaviour. Recorded as a
# contract objection in NOTES.md rather than changed unilaterally.
# ---------------------------------------------------------------------------

variable "rate_limit_ban_duration_sec" {
  description = "How long a client IP stays banned after exceeding rate_limit_threshold_per_minute. Finite by construction -- an infinite ban is an outage, a zero ban is no ban."
  type        = number
  default     = 600

  validation {
    condition     = var.rate_limit_ban_duration_sec > 0 && var.rate_limit_ban_duration_sec <= 86400 && floor(var.rate_limit_ban_duration_sec) == var.rate_limit_ban_duration_sec
    error_message = "rate_limit_ban_duration_sec must be a finite positive integer of at most 86400 seconds."
  }
}

variable "health_check_path" {
  description = "Unauthenticated health endpoint the load balancer probes on app_port. Must return 200 without credentials; every other path stays behind application OIDC."
  type        = string
  default     = "/healthz"

  validation {
    condition     = startswith(var.health_check_path, "/")
    error_message = "health_check_path must be an absolute path beginning with \"/\"."
  }
}

variable "backend_port_name" {
  description = "Named port on the backend instance group that the backend service targets. The compute module must declare a named_port with this name bound to app_port."
  type        = string
  default     = "http"
}
