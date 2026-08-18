# MUTANT of base.tfvars. kind = production — outside the enum. Expect ENV-RULE-02 and ENV-RULE-03.
#
# Exactly one thing is changed from base.tfvars; `diff base.tfvars kind-enum.tfvars`
# is the readable statement of what this fixture tests.

project_id = "sl-demo-platform"
target_env = "demo-1"

environments = {
  "demo-1" = {
    kind             = "production"
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
