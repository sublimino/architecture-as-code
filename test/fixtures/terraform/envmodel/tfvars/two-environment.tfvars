# VALID — two demo environments in one map, targeting the first.
#
# This is the executable half of the extensibility criterion (ISC-75). The
# committed example `terraform/environments/demo-1-and-demo-2.tfvars.example`
# proves textually that gaining demo-2 adds lines and changes none; this file
# proves the same thing *runs* — a second environment plans cleanly against the
# unmodified module and root.
#
# Both entries are declared while only demo-1 is applied, and that is
# deliberate: the unique-hostname and unique-subnet rules are cross-environment
# and cannot see a collision between demo-1 and demo-2 unless both are in scope.
# Narrowing to one environment happens at the for_each, after validation, not
# at the map.

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
  "demo-2" = {
    kind             = "demo"
    subnet_cidr      = "10.10.3.0/24"
    region           = "europe-west2"
    zone             = "europe-west2-a"
    machine_type     = "n2-standard-16"
    boot_disk_gb     = 200
    hostname         = "demo-2.example.invalid"
    allowed_ipv4     = ["192.0.2.0/24"]
    allowed_ipv6     = ["2001:db8::/32"]
    app_port         = 8080
    deletion_protect = false
    labels           = { tier = "demo" }
  }
}
