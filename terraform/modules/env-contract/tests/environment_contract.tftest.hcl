# The eleven contract rules, asserted against the EVALUATED configuration.
#
# CONTRACT.md §7a: this is the primary correctness surface. `expect_failures`
# is a first-class statement that a variable's validation rejected the input —
# no stderr parsing, no fixture root, no exit-code archaeology.
#
# ─── Every negative here is preceded by its corrected positive ───────────────
#
# A `run` block that fails for an unrelated reason — a mistyped field, a
# missing attribute in the object literal — is indistinguishable from a
# validation rule firing correctly. Both are "failed as expected". So each
# rule's positive run uses the SAME map with only the offending value
# corrected: if the literal is malformed, the positive goes red and the pair
# becomes uninterpretable rather than falsely green.
#
# ─── What this file deliberately does NOT assert ─────────────────────────────
#
# `expect_failures` names the variable that rejected, not the rule that fired.
# Eleven rules guard one variable, so this file proves "rejected" and cannot
# prove "rejected for the stated reason" — a mutant tripping the wrong rule
# reads identical here. `test/terraform-environment-keys.bats` covers exactly
# that gap: it asserts the exact set of ENV-RULE-NN tags in the plan output.
# The two surfaces are complementary, and neither subsumes the other.

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  environments = {
    "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24", "198.51.100.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = { tier = "demo" } }
    "ci-2"   = { kind = "ci", subnet_cidr = "10.10.2.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-8", boot_disk_gb = 100, hostname = "", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = false, labels = { tier = "ci" } }
  }
}

# ─── Baseline and the resolved values every other chunk consumes ─────────────

run "baseline_accepts_demo_1_and_ci_2" {
  command = plan

  assert {
    condition     = join(",", output.environment_keys) == "ci-2,demo-1"
    error_message = "both keys must be accepted and returned sorted"
  }
  assert {
    condition     = join(",", output.demo_keys) == "demo-1" && join(",", output.ci_keys) == "ci-2"
    error_message = "kind partitioning must follow the declared kind, not the key spelling"
  }
}

run "name_prefix_embeds_the_environment_key" {
  command = plan

  assert {
    condition     = output.name_prefix["demo-1"] == "sl-demo-1" && output.name_prefix["ci-2"] == "sl-ci-2"
    error_message = "name_prefix must be sl-<key> so no two environments can collide on a resource name"
  }
  assert {
    condition     = length(output.name_prefix["demo-1"]) <= 63
    error_message = "name_prefix must stay inside the GCP 63-character name limit"
  }
}

run "mandatory_labels_are_present_and_overridable" {
  command = plan

  assert {
    condition = alltrue([
      output.mandatory_labels["demo-1"]["environment"] == "demo-1",
      output.mandatory_labels["demo-1"]["kind"] == "demo",
      output.mandatory_labels["demo-1"]["managed-by"] == "terraform",
      output.mandatory_labels["demo-1"]["component"] == "signalloom",
    ])
    error_message = "the four mandatory labels must be computed for every environment"
  }
  assert {
    condition     = output.mandatory_labels["demo-1"]["tier"] == "demo"
    error_message = "an entry's own labels must be merged in, not dropped"
  }
}

run "uptime_targets_omit_environments_with_dns_disabled" {
  command = plan

  # ci-2 carries hostname = "", which is the sentinel for "no DNS record and no
  # public edge". An uptime check pointed at "" would be a monitor that can
  # never go green, alerting forever on an environment that is working.
  assert {
    condition     = join(",", keys(output.uptime_targets)) == "demo-1"
    error_message = "an environment with hostname = \"\" must not produce an uptime target"
  }
}

run "resolved_map_carries_every_downstream_module_input" {
  command = plan

  # CONTRACT.md §4 freezes these names. If this assertion drifts, a sibling
  # module's `each.value.<input>` silently becomes null rather than failing.
  assert {
    condition = alltrue([
      output.environments["demo-1"].environment_key == "demo-1",
      output.environments["demo-1"].name_prefix == "sl-demo-1",
      output.environments["demo-1"].region == "europe-west2",
      output.environments["demo-1"].zone == "europe-west2-a",
      output.environments["demo-1"].subnet_cidr == "10.10.1.0/24",
      output.environments["demo-1"].machine_type == "n2-standard-16",
      output.environments["demo-1"].boot_disk_gb == 200,
      output.environments["demo-1"].hostname == "demo-1.example.invalid",
      output.environments["demo-1"].app_port == 8080,
      output.environments["demo-1"].deletion_protect == true,
      output.environments["demo-1"].labels["component"] == "signalloom",
    ])
    error_message = "the resolved map must carry every CONTRACT.md §4 input under its frozen name"
  }
}

# ─── Rule 1 — key format ─────────────────────────────────────────────────────

run "rule01_accepts_demo_1" {
  command = plan
  variables {
    environments = {
      "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = {} }
    }
  }
  assert {
    condition     = join(",", output.environment_keys) == "demo-1"
    error_message = "demo-1 is the canonical valid key and must be accepted"
  }
}

run "rule01_rejects_demo_0" {
  command = plan
  variables {
    environments = {
      "demo-0" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = {} }
    }
  }
  expect_failures = [var.environments]
}

run "rule01_rejects_demo_01" {
  command = plan
  variables {
    environments = {
      "demo-01" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = {} }
    }
  }
  expect_failures = [var.environments]
}

run "rule01_rejects_prod_1" {
  command = plan
  variables {
    environments = {
      "prod-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = {} }
    }
  }
  expect_failures = [var.environments]
}

run "rule01_rejects_demo_underscore_1" {
  command = plan
  variables {
    environments = {
      "demo_1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = {} }
    }
  }
  expect_failures = [var.environments]
}

run "rule01_accepts_ci_2" {
  command = plan
  variables {
    environments = {
      "ci-2" = { kind = "ci", subnet_cidr = "10.10.2.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-8", boot_disk_gb = 100, hostname = "", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = false, labels = {} }
    }
  }
  assert {
    condition     = join(",", output.ci_keys) == "ci-2"
    error_message = "ci-2 is a valid key and must be accepted"
  }
}

# ─── Rules 2 and 3 — kind enum, and the key agreeing with its kind ───────────

run "rule02_rejects_kind_outside_the_enum" {
  command = plan
  variables {
    environments = {
      "demo-1" = { kind = "production", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = {} }
    }
  }
  expect_failures = [var.environments]
}

run "rule03_rejects_key_prefix_disagreeing_with_kind" {
  # A well-formed key and a well-formed kind that contradict each other. This
  # is the one that matters operationally: "ci-2" declaring kind = "demo" would
  # otherwise get a public load balancer because the modules filter on kind
  # while every human reading the plan filters on the key.
  command = plan
  variables {
    environments = {
      "ci-2" = { kind = "demo", subnet_cidr = "10.10.2.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-8", boot_disk_gb = 100, hostname = "", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = false, labels = {} }
    }
  }
  expect_failures = [var.environments]
}

# ─── Rules 4 and 5 — cross-environment collisions ────────────────────────────
#
# These are the rules that require the WHOLE map to be in scope. The root
# narrows to one environment at the for_each, after validation, never at the
# map — narrowing earlier would make a collision between two environments
# invisible precisely when a second environment is being added.

run "rule04_rejects_duplicate_hostnames" {
  command = plan
  variables {
    environments = {
      "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = {} }
      "demo-2" = { kind = "demo", subnet_cidr = "10.10.3.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = false, labels = {} }
    }
  }
  expect_failures = [var.environments]
}

run "rule04_accepts_two_empty_hostnames" {
  # "" is the DNS-disabled sentinel and is explicitly exempt from uniqueness.
  # Without the exemption, a second CI lane would be unaddable — the rule would
  # read two "no DNS" markers as a duplicate hostname.
  command = plan
  variables {
    environments = {
      "ci-1" = { kind = "ci", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-8", boot_disk_gb = 100, hostname = "", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = false, labels = {} }
      "ci-2" = { kind = "ci", subnet_cidr = "10.10.2.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-8", boot_disk_gb = 100, hostname = "", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = false, labels = {} }
    }
  }
  assert {
    condition     = length(output.uptime_targets) == 0
    error_message = "two DNS-disabled lanes must be accepted and must produce no uptime targets"
  }
}

run "rule05_rejects_duplicate_subnet_cidrs" {
  command = plan
  variables {
    environments = {
      "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = {} }
      "demo-2" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-2.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = false, labels = {} }
    }
  }
  expect_failures = [var.environments]
}

run "rule06b_rejects_a_supernet_that_contains_another_subnet" {
  # 10.10.0.0/16 CONTAINS 10.10.1.0/24 while being a distinct string, so rule 5
  # cannot see it. Constraining every subnet to a /24 makes uniqueness and
  # non-overlap the same property. See NOTES.md — this rule is an addition to
  # the eleven, not one of them.
  command = plan
  variables {
    environments = {
      "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = {} }
      "demo-2" = { kind = "demo", subnet_cidr = "10.10.0.0/16", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-2.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = false, labels = {} }
    }
  }
  expect_failures = [var.environments]
}

# ─── Rule 6 — subnets are RFC1918 ────────────────────────────────────────────

run "rule06_rejects_public_address_space" {
  command = plan
  variables {
    environments = {
      "demo-1" = { kind = "demo", subnet_cidr = "198.51.100.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = {} }
    }
  }
  expect_failures = [var.environments]
}

run "rule06_accepts_all_three_rfc1918_blocks" {
  command = plan
  variables {
    environments = {
      "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = {} }
      "demo-2" = { kind = "demo", subnet_cidr = "172.16.4.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-2.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = false, labels = {} }
      "demo-3" = { kind = "demo", subnet_cidr = "192.168.7.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-3.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = false, labels = {} }
    }
  }
  assert {
    condition     = length(output.environment_keys) == 3
    error_message = "10/8, 172.16/12 and 192.168/16 must all be accepted"
  }
}

# ─── Rules 7 to 10 — allowlists ──────────────────────────────────────────────

run "rule07_rejects_a_malformed_ipv4_entry" {
  command = plan
  variables {
    environments = {
      "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["198.51.100.999"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = {} }
    }
  }
  expect_failures = [var.environments]
}

run "rule08_rejects_a_malformed_ipv6_entry" {
  command = plan
  variables {
    environments = {
      "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::zz/32"], app_port = 8080, deletion_protect = true, labels = {} }
    }
  }
  expect_failures = [var.environments]
}

run "rule09_rejects_any_source_ipv4" {
  # The single most consequential rule in the file: 0.0.0.0/0 in an allowlist
  # is the difference between a demo reachable by the customer and a demo
  # reachable by everyone with a port scanner.
  command = plan
  variables {
    environments = {
      "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["0.0.0.0/0"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = {} }
    }
  }
  expect_failures = [var.environments]
}

run "rule09_rejects_any_source_ipv4_in_disguise" {
  # 128.0.0.0/0 is 0.0.0.0/0 wearing a hat: any /0 covers the whole space
  # regardless of the address written in front of it. A rule matching only the
  # literal string would be trivially bypassed by someone who thought they were
  # being clever, and would look correct in review.
  command = plan
  variables {
    environments = {
      "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["128.0.0.0/0"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = {} }
    }
  }
  expect_failures = [var.environments]
}

run "rule10_rejects_any_source_ipv6" {
  command = plan
  variables {
    environments = {
      "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["::/0"], app_port = 8080, deletion_protect = true, labels = {} }
    }
  }
  expect_failures = [var.environments]
}

run "rules_07_to_10_accept_documentation_ranges" {
  # The corrected pair for all four allowlist rules: RFC5737 and RFC3849
  # ranges, which are exactly what the shipped examples use.
  command = plan
  variables {
    environments = {
      "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = {} }
    }
  }
  assert {
    condition     = length(output.environments["demo-1"].allowed_ipv4) == 3
    error_message = "well-formed documentation-range allowlists must pass through unchanged"
  }
}

# ─── Rule 11 — app_port ──────────────────────────────────────────────────────

run "rule11_rejects_port_zero" {
  command = plan
  variables {
    environments = {
      "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 0, deletion_protect = true, labels = {} }
    }
  }
  expect_failures = [var.environments]
}

run "rule11_rejects_port_70000" {
  command = plan
  variables {
    environments = {
      "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 70000, deletion_protect = true, labels = {} }
    }
  }
  expect_failures = [var.environments]
}

run "rule11_accepts_the_boundary_ports" {
  # 1 and 65535 are inside the range. A rule written with > and < rather than
  # >= and <= would reject both and nobody would notice until someone used a
  # privileged port on purpose.
  command = plan
  variables {
    environments = {
      "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 1, deletion_protect = true, labels = {} }
      "demo-2" = { kind = "demo", subnet_cidr = "10.10.2.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-2.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 65535, deletion_protect = false, labels = {} }
    }
  }
  assert {
    condition     = output.environments["demo-1"].app_port == 1 && output.environments["demo-2"].app_port == 65535
    error_message = "ports 1 and 65535 are inside the TCP range and must be accepted"
  }
}

# Regression for an adversarial-review finding on ENV-RULE-09 / ENV-RULE-10.
#
# Both rules rejected any /0, which reads as thorough — 128.0.0.0/0 is caught as
# well as 0.0.0.0/0. It is still not enough. ["0.0.0.0/1", "128.0.0.0/1"] is two
# valid CIDRs, neither a /0, and between them they are every IPv4 address on the
# internet. Prefix length is the property that actually means "not the internet".
run "rule_09_rejects_the_split_ipv4_internet" {
  command = plan
  variables {
    environments = {
      "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["0.0.0.0/1", "128.0.0.0/1"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = {} }
    }
    target_env = "demo-1"
  }
  expect_failures = [var.environments]
}

run "rule_10_rejects_the_split_ipv6_internet" {
  command = plan
  variables {
    environments = {
      "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["::/1", "8000::/1"], app_port = 8080, deletion_protect = true, labels = {} }
    }
    target_env = "demo-1"
  }
  expect_failures = [var.environments]
}

# Paired positive: a rule that rejected everything would satisfy both negatives
# above while breaking every real environment.
run "rules_09_and_10_still_accept_realistic_ranges" {
  command = plan
  variables {
    environments = {
      "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24", "198.51.100.128/25"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = {} }
    }
    target_env = "demo-1"
  }
  assert {
    condition     = length(var.environments) == 1
    error_message = "a realistic allowlist must still plan cleanly, or the two negatives above prove nothing"
  }
}
