# `modules/network`

One custom-mode VPC per Signal Loom environment, private by construction.

## What it creates

| Resource | Notes |
|---|---|
| `google_compute_network` | Custom mode (`auto_create_subnetworks = false`), regional routing. |
| `google_compute_subnetwork` | One per environment, `private_ip_google_access = true`, flow logs on with an explicit sampling config. |
| `google_compute_router` | Regional, for NAT. |
| `google_compute_router_nat` | Scoped to this subnet only (`LIST_OF_SUBNETWORKS`), logging on with a configurable filter. |
| 2 ingress allow rules | IAP SSH; GCP health-check / LB ranges on the app port. Both scoped by target service account. |
| 1 ingress deny rule | Explicit default-deny at priority 65534, logged. |
| 3–4 egress allow rules | DNS, Google APIs, intra-subnet, and optionally operator-named public HTTPS. |
| 1 egress deny rule | Default-deny at priority 65534, logged. Replaces GCP's implied allow-all. |

## Inputs

Per `terraform/CONTRACT.md` §4:

| Name | Type | Default |
|---|---|---|
| `project_id` | string | — |
| `environment_key` | string | — |
| `name_prefix` | string | — |
| `labels` | map(string) | — |
| `region` | string | — |
| `subnet_cidr` | string | — |
| `app_port` | number | — |
| `runtime_service_account_email` | string | — |
| `nat_log_filter` | string | `"ERRORS_ONLY"` |

Additive, all optional, all defaulted — callers wiring against the contract need set none of them:

| Name | Type | Default |
|---|---|---|
| `flow_log_aggregation_interval` | string | `"INTERVAL_5_SEC"` |
| `flow_log_sampling_rate` | number | `0.5` |
| `enable_default_deny_egress` | bool | `true` |
| `egress_public_https_destinations` | list(string) | `[]` |

## Outputs

`network_self_link`, `subnet_self_link`, `network_tag`, `subnet_cidr`.

## READ THIS BEFORE YOU APPLY: the egress default is closed

**`enable_default_deny_egress` defaults to `true` and `egress_public_https_destinations`
defaults to `[]`. With the defaults, an applied environment cannot pull public container
images.** Docker Hub, ghcr.io, quay.io, and the Debian mirrors publish no stable address
range, so there is no honest way to allowlist them in a module default.

That is deliberate, and it is the opposite of the usual shape. "NAT is not egress control"
is a named threat in the proposal: Cloud NAT gives a private VM outbound reach to the entire
internet, and GCP's implied allow-all egress at priority 65535 means nothing stops it. A
module variable that defaults open is precisely how that threat survives a security review —
it reads as configurable while behaving as unconstrained.

To let an environment pull images, name the destinations in that environment's tfvars:

```hcl
egress_public_https_destinations = [
  "192.0.2.0/24",    # replace with the registry ranges you have actually resolved
  "198.51.100.0/24",
]
```

The line is then reviewable, diffable, and attributable to a person. A module default is
none of those things.

If you need the demo to work before you have resolved those ranges, set
`enable_default_deny_egress = false` for that environment and record why. It is a worse
posture, but an explicit one — the plan output shows the deny rule being destroyed.

## Allowed egress dependency list

Enumerated in the comment block above the egress rules in `main.tf`. In short:

1. **DNS** — UDP/TCP 53 to `169.254.169.254` (metadata server). Everything else depends on it.
2. **Google APIs** — TCP 443 to `199.36.153.4/30` and `199.36.153.8/30`. Cloud Logging,
   Cloud Monitoring, OS Login lookups, Artifact Registry via Private Google Access.
3. **Intra-subnet** — TCP/UDP/ICMP within `var.subnet_cidr`, for the Kind cluster.
4. **Public HTTPS** — TCP 443 to operator-named destinations only. No default.

## Firewall scoping

Every allow rule sets `target_service_accounts = [var.runtime_service_account_email]`. A
rule with no target applies to every instance in the VPC, so "SSH is reachable on the demo
VM" silently becomes "SSH is reachable on anything anyone launches in this network". The
identity chunk (F5) supplies the per-environment service account.

## The one `0.0.0.0/0` in this module

Two rules carry `0.0.0.0/0`: the default-deny ingress (`source_ranges`) and the default-deny
egress (`destination_ranges`). Both are **deny** rules — that is what "deny everything not
otherwise allowed" means, and there is no other way to express it. No `allow` rule anywhere
in this module has `0.0.0.0/0` in `source_ranges`, and `test/terraform-network-security.bats`
asserts exactly that distinction rather than banning the string outright. A guard that banned
the string would force the default-deny rule out of the tree, which is the wrong outcome.
