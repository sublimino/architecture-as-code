# The valid baseline. Every negative fixture in this directory is this file
# with ONE thing changed, and every negative test proves this file plans
# cleanly before asserting that its own mutant does not.
#
# That ordering is the whole point. A validation failure caused by an unrelated
# syntax error in the fixture root reads exactly like a correctly-firing rule:
# non-zero exit, an error on stderr, a green test. Proving the baseline green
# first is what tells the two apart.
#
# demo-1 and ci-2 together also discharge the "key regex accepts demo-1 and
# ci-2" criterion — the acceptance case is the baseline, not a separate file.

project_id = "sl-demo-platform"
target_env = "demo-1"

environments = {
  "demo-1" = {
    kind             = "demo"
    subnet_cidr      = "10.10.1.0/24"
    region           = "europe-west2"
    zone             = "europe-west2-a"
    machine_type     = "n2-standard-16"
    boot_disk_gb     = 200
    hostname         = "demo-1.example.invalid"
    allowed_ipv4     = ["192.0.2.0/24", "198.51.100.0/24"]
    allowed_ipv6     = ["2001:db8::/32"]
    app_port         = 8080
    deletion_protect = true
    labels           = { tier = "demo" }
  }
  "ci-2" = {
    kind             = "ci"
    subnet_cidr      = "10.10.2.0/24"
    region           = "europe-west2"
    zone             = "europe-west2-a"
    machine_type     = "n2-standard-8"
    boot_disk_gb     = 100
    hostname         = ""
    allowed_ipv4     = ["192.0.2.0/24"]
    allowed_ipv6     = ["2001:db8::/32"]
    app_port         = 8080
    deletion_protect = false
    labels           = { tier = "ci" }
  }
}
