# Regression for an adversarial-review finding.
#
# The rule was `c != "0.0.0.0/0"` — a literal spelling compare. The pair
# ["0.0.0.0/1", "128.0.0.0/1"] covers every IPv4 address, parses as two valid
# CIDRs, fits the 500-entry cap, and would have been allow-listed at priority
# 1000 above the Cloud Armor default deny. The IPv6 equivalent is ["::/1",
# "8000::/1"]. Both are now rejected on prefix length.

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  # Allowlist-width validations fire regardless of mode, but this file is about
  # the allowlist being load-bearing, so it says so.
  access_mode            = "allowlist"
  project_id             = "changeme-project"
  environment_key        = "demo-1"
  name_prefix            = "sl-demo-1"
  labels                 = { environment = "demo-1" }
  hostname               = ""
  dns_managed_zone       = ""
  backend_instance_group = "projects/changeme-project/zones/europe-west2-a/instanceGroups/sl-demo-1-ig"
  app_port               = 8080
  allowed_ipv4           = ["192.0.2.0/24"]
  allowed_ipv6           = []
}

run "rejects_the_split_ipv4_internet" {
  command = plan
  variables { allowed_ipv4 = ["0.0.0.0/1", "128.0.0.0/1"] }
  expect_failures = [var.allowed_ipv4]
}

run "rejects_a_bare_zero_prefix_ipv4" {
  command = plan
  variables { allowed_ipv4 = ["0.0.0.0/0"] }
  expect_failures = [var.allowed_ipv4]
}

run "rejects_the_split_ipv6_internet" {
  command = plan
  variables { allowed_ipv6 = ["::/1", "8000::/1"] }
  expect_failures = [var.allowed_ipv6]
}

run "rejects_an_out_of_range_ipv6_prefix_length" {
  command = plan
  variables { allowed_ipv6 = ["2001:db8::/999"] }
  expect_failures = [var.allowed_ipv6]
}

# The paired positive. Without it, a rule that rejected EVERYTHING would make
# all four negatives above pass while breaking every real environment.
run "accepts_realistic_narrow_ranges" {
  command = plan
  variables {
    allowed_ipv4 = ["192.0.2.0/24", "198.51.100.128/25"]
    allowed_ipv6 = ["2001:db8::/32"]
  }
  assert {
    condition     = length(var.allowed_ipv4) == 2
    error_message = "a realistic allowlist must still plan cleanly, or the negatives above prove nothing"
  }
}
