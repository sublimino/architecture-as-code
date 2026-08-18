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

variable "access_mode" {
  description = <<-EOT
    How the edge decides who may reach the application. Exactly three legal values.

      "iap"                Identity-Aware Proxy authenticates and authorises every
                           request at the Google edge before any byte reaches the
                           backend. An unauthenticated visitor gets a Google sign-in,
                           not the app. Access is a named list of principals
                           (var.iap_members), not a list of IP ranges. THIS IS THE
                           DEFAULT: the safe posture is what you get by not thinking
                           about it.

      "allowlist"          Cloud Armor's IP allowlist is the only authorisation
                           control. Retained for a genuinely public demo. This is
                           coarse EXPOSURE control and is NOT authentication --
                           anyone on an allowlisted network is admitted as anyone.

      "iap_and_allowlist"  Both. IAP authenticates, and Cloud Armor additionally
                           narrows which networks may even reach the sign-in page.
                           Defence in depth, and the strongest posture available.
  EOT
  type        = string
  default     = "iap"

  validation {
    condition     = contains(["iap", "allowlist", "iap_and_allowlist"], var.access_mode)
    error_message = "access_mode must be exactly one of \"iap\", \"allowlist\", or \"iap_and_allowlist\"."
  }
}

variable "iap_members" {
  description = "IAM principals granted roles/iap.httpsResourceAccessor, e.g. [\"user:someone@example.invalid\"]. Required (non-empty) whenever access_mode includes IAP: IAP with no authorised principal is a locked door with no key, and the failure mode is a demo nobody can open."
  type        = list(string)
  default     = []

  # An empty list under an IAP mode is not a safe default, it is an outage that
  # only announces itself at demo time. Fail at plan instead.
  validation {
    condition     = !contains(["iap", "iap_and_allowlist"], var.access_mode) || length(var.iap_members) > 0
    error_message = "access_mode includes IAP but iap_members is empty. IAP with no authorised principal locks everyone out, including you. Name at least one principal, e.g. [\"user:someone@example.invalid\"]."
  }

  # The single most dangerous line in this module. "allAuthenticatedUsers" reads
  # as a restriction -- the word "authenticated" is right there -- and in IAP it
  # means ANY Google account on earth. That is functionally public access wearing
  # the vocabulary of access control. "allUsers" is public without the disguise.
  # Compared case-insensitively: only one spelling is valid to the API, but a
  # guard that a typo walks past is a guard that teaches false confidence.
  #
  # The wildcard clause is what makes this rule independently testable, and it
  # was added because of a real gap. The prefix rule below ALSO rejects both
  # bare tokens (neither carries a "type:" prefix), so deleting this entire
  # block left the suite green -- the most dangerous guard in the module had no
  # test that could see it disappear. A wildcard principalSet is prefix-valid,
  # so only this rule can reject it, and now a mutation here goes red.
  #
  # It is also a real footgun in its own right: a member such as
  # "principalSet://iam.googleapis.com/.../workloadIdentityPools/pool/*" reads
  # as a scoped grant and admits every identity in the pool.
  validation {
    condition = alltrue([
      for m in var.iap_members :
      !contains(["allusers", "allauthenticatedusers"], lower(trimspace(m)))
      && !strcontains(m, "*")
    ])
    error_message = "iap_members contains allUsers, allAuthenticatedUsers, or a wildcard. None is a restriction: allUsers is the public internet, allAuthenticatedUsers is every Google account in existence, and a wildcard principalSet admits every identity in the pool. Name principals explicitly."
  }

  # Structural backstop for the rule above. Every legal IAM member carries a type
  # prefix; the two dangerous values are precisely the ones that do not. This
  # also rejects a bare email address, which silently grants nothing at all.
  validation {
    condition = alltrue([
      for m in var.iap_members :
      can(regex("^(user|group|serviceAccount|domain|principal|principalSet):[^[:space:]]+$", trimspace(m)))
    ])
    error_message = "Every iap_members entry must be a prefixed IAM principal such as \"user:...\", \"group:...\", \"serviceAccount:...\", or \"domain:...\". A bare email address is not a valid member and grants no access."
  }
}

variable "iap_oauth2_client_id" {
  description = "OAuth2 client id for IAP. Leave empty (the default) to use the IAP-managed OAuth client, which requires no brand or client to be provisioned by hand and keeps a client secret out of tfvars entirely. Set both this and iap_oauth2_client_secret only when an externally-managed client is genuinely required."
  type        = string
  default     = ""
}

variable "iap_oauth2_client_secret" {
  description = "OAuth2 client secret matching iap_oauth2_client_id. Empty by default because the IAP-managed client needs no secret. Never commit a real value; supply it from a secret manager at apply time."
  type        = string
  default     = ""
  sensitive   = true

  # Half a client pair is not a degraded configuration, it is a broken one: the
  # provider would send an id with no secret and IAP would reject every sign-in.
  validation {
    condition     = (var.iap_oauth2_client_id == "") == (var.iap_oauth2_client_secret == "")
    error_message = "iap_oauth2_client_id and iap_oauth2_client_secret must be set together or both left empty. Leaving both empty selects the IAP-managed OAuth client, which is the recommended form."
  }
}

variable "allowed_ipv4" {
  description = "IPv4 CIDRs permitted at the edge. COARSE EXPOSURE CONTROL ONLY -- this is not authentication. Never 0.0.0.0/0. An empty list is legal and means the default deny is the only rule, which is the safe state. Consulted for authorisation only when access_mode is \"allowlist\" or \"iap_and_allowlist\"."
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
