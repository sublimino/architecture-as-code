# Naming and labelling locals. Verbatim from `terraform/CONTRACT.md` §3.
#
# This module deliberately declares no resources and no provider. It is a pure
# contract: a type, its validation rules, and the derived names and labels that
# every other module is required to use rather than inventing its own scheme.
# Being resource-free is also what makes it testable offline — a root assembled
# from these files needs no provider plugin and no credentials.

locals {
  # Deterministic, key-embedded, and <= 63 chars for GCP name limits.
  name_prefix = { for k, v in var.environments : k => "sl-${k}" }

  mandatory_labels = { for k, v in var.environments : k => merge(
    {
      environment = k
      kind        = v.kind
      managed-by  = "terraform"
      component   = "signalloom"
    },
    v.labels,
  ) }

  # The resolved per-environment view. Every field a consuming module needs is
  # present here under the exact input name from CONTRACT.md §4, so a root can
  # write `for_each = module.env_contract.environments` and then reference
  # `each.value.<input>` with no per-environment lookup tables and no
  # per-environment module blocks. That is the mechanism behind ISC-75:
  # adding demo-2 is a new map entry in a tfvars file and nothing else.
  resolved = { for k, v in var.environments : k => {
    environment_key  = k
    kind             = v.kind
    name_prefix      = local.name_prefix[k]
    labels           = local.mandatory_labels[k]
    region           = v.region
    zone             = v.zone
    subnet_cidr      = v.subnet_cidr
    machine_type     = v.machine_type
    boot_disk_gb     = v.boot_disk_gb
    hostname         = v.hostname
    allowed_ipv4     = v.allowed_ipv4
    allowed_ipv6     = v.allowed_ipv6
    app_port         = v.app_port
    deletion_protect = v.deletion_protect
  } }
}
