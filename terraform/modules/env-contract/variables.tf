# The environment contract.
#
# This file is the single most-shared interface in the Terraform tree: every
# other chunk consumes the object type declared here, and every environment
# that will ever exist is one entry in the map. See `terraform/CONTRACT.md` §3.
#
# ─── Why each rule is its own validation block ──────────────────────────────
#
# Terraform evaluates every `validation` block and reports each failing one
# separately, quoting its own `error_message`. Folding eleven rules into one
# block would still fail closed, but the operator would be told only "the map
# is wrong" — and a test asserting on stderr could not tell which rule fired,
# so a test written for rule 9 would pass when rule 3 was the thing that broke.
# Each message therefore opens with a stable `ENV-RULE-NN-<NAME>:` tag, and
# `test/terraform-environment-keys.bats` asserts on that tag, not on any error.
#
# ─── Why the conditions never let an error escape ───────────────────────────
#
# Terraform's `&&` is not guaranteed to short-circuit, so any sub-expression
# that can *error* on malformed input (rather than return false) is wrapped in
# `can(...)` individually. `can(regex(..., cidrhost(c, 0)))` catches a failure
# in `cidrhost` as well as in `regex`. A condition that errors instead of
# returning false produces an opaque crash rather than the named rule.

variable "environments" {
  description = "Typed map of every Signal Loom environment, keyed by stable environment key."
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

  # Rule 1 — key format.
  validation {
    condition = alltrue([
      for k in keys(var.environments) : can(regex("^(demo|ci)-[1-9][0-9]*$", k))
    ])
    error_message = format(
      "ENV-RULE-01-KEY-FORMAT: every environments key must match ^(demo|ci)-[1-9][0-9]*$; rejected: %s.",
      join(", ", [for k in keys(var.environments) : k if !can(regex("^(demo|ci)-[1-9][0-9]*$", k))]),
    )
  }

  # Rule 2 — kind enum.
  validation {
    condition = alltrue([
      for v in values(var.environments) : contains(["demo", "ci"], v.kind)
    ])
    error_message = format(
      "ENV-RULE-02-KIND-ENUM: every entry's kind must be \"demo\" or \"ci\"; rejected: %s.",
      join(", ", [for k, v in var.environments : "${k}=${v.kind}" if !contains(["demo", "ci"], v.kind)]),
    )
  }

  # Rule 3 — the key's prefix agrees with its kind.
  validation {
    condition = alltrue([
      for k, v in var.environments : startswith(k, "${v.kind}-")
    ])
    error_message = format(
      "ENV-RULE-03-KEY-KIND-AGREE: each key must start with its own kind; rejected: %s.",
      join(", ", [for k, v in var.environments : "${k} declares kind=${v.kind}" if !startswith(k, "${v.kind}-")]),
    )
  }

  # Rule 4 — hostnames unique, ignoring the "" (DNS disabled) sentinel.
  validation {
    condition = length([for v in values(var.environments) : v.hostname if v.hostname != ""]) == length(
      distinct([for v in values(var.environments) : v.hostname if v.hostname != ""])
    )
    error_message = format(
      "ENV-RULE-04-HOSTNAME-UNIQUE: hostname values must be unique across the map (\"\" is exempt); duplicated: %s.",
      join(", ", distinct([
        for v in values(var.environments) : v.hostname
        if v.hostname != "" && length([for w in values(var.environments) : w.hostname if w.hostname == v.hostname]) > 1
      ])),
    )
  }

  # Rule 5 — subnet CIDRs unique.
  validation {
    condition = length([for v in values(var.environments) : v.subnet_cidr]) == length(
      distinct([for v in values(var.environments) : v.subnet_cidr])
    )
    error_message = format(
      "ENV-RULE-05-SUBNET-UNIQUE: subnet_cidr values must be unique across the map; duplicated: %s.",
      join(", ", distinct([
        for v in values(var.environments) : v.subnet_cidr
        if length([for w in values(var.environments) : w.subnet_cidr if w.subnet_cidr == v.subnet_cidr]) > 1
      ])),
    )
  }

  # Rule 6 — subnet CIDRs parse as IPv4 CIDRs and are RFC1918.
  validation {
    condition = alltrue([
      for v in values(var.environments) : (
        can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$", v.subnet_cidr))
        && can(cidrhost(v.subnet_cidr, 0))
        && can(regex("^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)", cidrhost(v.subnet_cidr, 0)))
      )
    ])
    error_message = format(
      "ENV-RULE-06-SUBNET-RFC1918: subnet_cidr must be a parseable IPv4 CIDR inside 10/8, 172.16/12 or 192.168/16; rejected: %s.",
      join(", ", [
        for k, v in var.environments : "${k}=${v.subnet_cidr}"
        if !(
          can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$", v.subnet_cidr))
          && can(cidrhost(v.subnet_cidr, 0))
          && can(regex("^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)", cidrhost(v.subnet_cidr, 0)))
        )
      ]),
    )
  }

  # Rule 6B — subnet CIDRs are exactly /24. NOT one of the eleven contract
  # rules; see README.md "Contract extension" and NOTES.md. This is what makes
  # rule 5 (uniqueness) equivalent to non-overlap: two /24s intersect if and
  # only if they are the same /24, so a pair like 10.10.0.0/16 + 10.10.1.0/24
  # is rejected here rather than needing inline 32-bit containment arithmetic
  # in a condition that may not reference locals.
  validation {
    condition = alltrue([
      for v in values(var.environments) : can(regex("/24$", v.subnet_cidr))
    ])
    error_message = format(
      "ENV-RULE-06B-SUBNET-PREFIX-24: subnet_cidr must be a /24 so that uniqueness implies non-overlap; rejected: %s.",
      join(", ", [for k, v in var.environments : "${k}=${v.subnet_cidr}" if !can(regex("/24$", v.subnet_cidr))]),
    )
  }

  # Rule 7 — every allowed_ipv4 entry parses as an IPv4 CIDR.
  validation {
    condition = alltrue(flatten([
      for v in values(var.environments) : [
        for c in v.allowed_ipv4 : (
          can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$", c)) && can(cidrhost(c, 0))
        )
      ]
    ]))
    error_message = format(
      "ENV-RULE-07-IPV4-CIDR: every allowed_ipv4 entry must parse as an IPv4 CIDR; rejected: %s.",
      join(", ", flatten([
        for k, v in var.environments : [
          for c in v.allowed_ipv4 : "${k}=${c}"
          if !(can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$", c)) && can(cidrhost(c, 0)))
        ]
      ])),
    )
  }

  # Rule 8 — every allowed_ipv6 entry parses as an IPv6 CIDR.
  validation {
    condition = alltrue(flatten([
      for v in values(var.environments) : [
        for c in v.allowed_ipv6 : (
          can(regex("^[0-9A-Fa-f:.]+/[0-9]{1,3}$", c)) && strcontains(c, ":") && can(cidrhost(c, 0))
        )
      ]
    ]))
    error_message = format(
      "ENV-RULE-08-IPV6-CIDR: every allowed_ipv6 entry must parse as an IPv6 CIDR; rejected: %s.",
      join(", ", flatten([
        for k, v in var.environments : [
          for c in v.allowed_ipv6 : "${k}=${c}"
          if !(can(regex("^[0-9A-Fa-f:.]+/[0-9]{1,3}$", c)) && strcontains(c, ":") && can(cidrhost(c, 0)))
        ]
      ])),
    )
  }

  # Rule 9 — no any-source IPv4. Any /0 is rejected, not just the literal
  # 0.0.0.0/0: 128.0.0.0/0 is the same allowlist wearing a disguise.
  validation {
    condition = alltrue(flatten([
      for v in values(var.environments) : [
        for c in v.allowed_ipv4 : c != "0.0.0.0/0" && !can(regex("/0$", c))
      ]
    ]))
    error_message = format(
      "ENV-RULE-09-NO-ANY-IPV4: allowed_ipv4 must not contain 0.0.0.0/0 or any other /0; rejected: %s.",
      join(", ", flatten([
        for k, v in var.environments : [
          for c in v.allowed_ipv4 : "${k}=${c}" if c == "0.0.0.0/0" || can(regex("/0$", c))
        ]
      ])),
    )
  }

  # Rule 10 — no any-source IPv6.
  validation {
    condition = alltrue(flatten([
      for v in values(var.environments) : [
        for c in v.allowed_ipv6 : c != "::/0" && !can(regex("/0$", c))
      ]
    ]))
    error_message = format(
      "ENV-RULE-10-NO-ANY-IPV6: allowed_ipv6 must not contain ::/0 or any other /0; rejected: %s.",
      join(", ", flatten([
        for k, v in var.environments : [
          for c in v.allowed_ipv6 : "${k}=${c}" if c == "::/0" || can(regex("/0$", c))
        ]
      ])),
    )
  }

  # Rule 11 — app_port is a whole number in the TCP port range.
  validation {
    condition = alltrue([
      for v in values(var.environments) : v.app_port >= 1 && v.app_port <= 65535 && floor(v.app_port) == v.app_port
    ])
    error_message = format(
      "ENV-RULE-11-APP-PORT-RANGE: app_port must be a whole number between 1 and 65535; rejected: %s.",
      join(", ", [
        for k, v in var.environments : "${k}=${v.app_port}"
        if !(v.app_port >= 1 && v.app_port <= 65535 && floor(v.app_port) == v.app_port)
      ]),
    )
  }
}
