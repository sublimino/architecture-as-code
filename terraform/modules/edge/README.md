# `modules/edge` — the Signal Loom public security boundary

Replaces the ngrok tunnel with a global external Application Load Balancer: TLS 1.2 floor,
Google-managed certificate, a redirect-only port 80 listener, and a Cloud Armor policy whose
**default action is `deny(403)`**.

---

## Access modes — pick the posture, not the plumbing

The module has three postures, selected by `access_mode`. **The default is `iap`**, because a
variable that defaults to the weaker posture is how the weaker posture reaches production.

| `access_mode` | Who decides access | Use it when |
|---|---|---|
| **`iap`** (default) | **Identity-Aware Proxy.** Google authenticates and authorises every request at the edge, before any byte reaches the backend. An unauthenticated visitor gets a Google sign-in page, not the app. Access is `iap_members` — a named list of principals. | You want to route to it without it being public. This is the answer to "I want to be able to reach it, but not have public access so it stays secure." |
| `allowlist` | **Cloud Armor's IP allowlist**, and nothing else. Coarse exposure control, not authentication. | A genuinely public demo where you only want to narrow the blast radius. |
| `iap_and_allowlist` | **Both.** IAP authenticates, and Cloud Armor additionally narrows which networks may even reach the sign-in page. | Defence in depth. The strongest posture available, and the one to prefer for anything sensitive. |

### What IAP does that an allowlist cannot

An allowlist answers *where a request came from*. IAP answers *who made it*. Those are different
questions, and only the second one is access control. IAP issues a signed assertion after a real
Google sign-in; an allowlist grants a shared network the right to be anyone.

### `allAuthenticatedUsers` is not a restriction

The most dangerous value this module can be given. The word "authenticated" reads as a
constraint, and in IAP it means **any Google account on earth** — every Gmail address, every
Workspace tenant. It is functionally public access wearing the vocabulary of access control.
`allUsers` is the same thing without the disguise. Both are rejected by variable validation, as
is any wildcard member such as a `principalSet:` ending in `/*`.

### Why `iap` mode does not narrow Cloud Armor by IP

On a global external Application Load Balancer, **Cloud Armor is evaluated before IAP**, against
the *original client IP*:

> "For a backend service of a global external Application Load Balancer, Cloud Armor evaluation
> happens first. If Cloud Armor blocks a request, IAP doesn't evaluate the request."
> — [Integrate with other Google products](https://cloud.google.com/armor/docs/integrating-cloud-armor)

IAP is an inline check at the same Google front end, not an upstream proxy with its own source
addresses. So in `iap` mode Cloud Armor must admit the clients IAP is going to authenticate; a
policy that admitted only "Google's IAP range" would return `403` to every real browser and the
sign-in page would never appear. (`35.235.240.0/20` is the IAP **TCP-forwarding** range, which
governs the VPC firewall for SSH tunnelling — it carries no web traffic through this load
balancer.)

The wildcard allow rule in `iap` mode therefore widens **exposure**, not **authorisation**.
Everything behind it still has to pass IAP. The Cloud Armor default `deny(403)`, the
preconfigured WAF denies, adaptive protection, and rate limiting are retained in every mode — a
resource precondition makes a wildcard allow unrepresentable while IAP is off.

### OAuth client

`iap_oauth2_client_id` and `iap_oauth2_client_secret` are empty by default, which selects the
**IAP-managed OAuth client**: no brand or client to provision by hand, and no client secret in
tfvars or in state. Set both only when an externally-managed client is genuinely required.

---

## The one thing to read before using this module

**The IP allowlist is coarse exposure control. It is not authentication.**

An address on `allowed_ipv4` / `allowed_ipv6` has been granted the right to *reach* the
application and nothing more. It has not been identified, it has not been authorised, and it
carries no session. Application OIDC stays mandatory behind this module and is the only control
that establishes who a caller is.

This matters because the failure is quiet and the reasoning that produces it is comfortable. A
source IP is not a principal:

- Office and VPN egress ranges are shared by everyone on that network, including contractors,
  guests, and any device that has been compromised.
- Cloud NAT and corporate proxy pools are reassigned. The range you allowlisted in March belongs
  to a different set of people by September.
- An SSRF or an open redirect inside an allowlisted network turns any internal service into a
  proxy for an external attacker, from an address the edge trusts.
- Allowlists rot upward. Nobody has ever removed a CIDR in a hurry; ranges get widened during an
  incident and are not narrowed afterwards.

`scripts/gcp-tf/edge-probe-positive.sh` exists precisely to catch the moment this stops being
true. It probes from an allowlisted source **with no credentials** and **fails on an anonymous
HTTP 200**. A 200 means network position alone granted access — the allowlist has silently
become the authentication control. The probe exits `3` and says so in those words.

---

## The backend must not trust client-supplied identity headers

Identity headers are a plain-text assertion that anyone can make. `X-Forwarded-User: alice` costs
an attacker one line of `curl`. If the application ever reads such a header without verifying a
signature, every control in this module is bypassed by a header.

Two things follow, and both are required — neither is sufficient alone.

**1. The edge strips them.** The HTTPS URL map removes the headers below on every request, before
the backend sees it, so a forged client header can never be mistaken for one asserted by an
authenticating proxy:

```hcl
path_matcher {
  name            = "all"
  default_service = google_compute_backend_service.app.id

  header_action {
    request_headers_to_remove = [
      "X-Auth-Request-Email", "X-Auth-Request-Groups", "X-Auth-Request-User",
      "X-Forwarded-Client-Cert", "X-Forwarded-Email", "X-Forwarded-User",
      "X-Goog-Authenticated-User-Email", "X-Goog-Authenticated-User-Id",
      "X-Goog-Iap-Jwt-Assertion",
      "X-Remote-Groups", "X-Remote-User",
      "X-Signalloom-Role", "X-Signalloom-Tenant",
    ]
  }
}
```

If a trusted proxy genuinely needs to assert identity to the backend, override rather than strip —
the edge sets the value unconditionally, so a client-supplied one is discarded whatever it said:

```hcl
header_action {
  request_headers_to_add {
    header_name  = "X-Signalloom-Edge-Verified"
    header_value = "true"
    replace      = true # replace = true is the whole point; false appends and preserves the forgery
  }
}
```

`X-Forwarded-For` is deliberately **not** stripped. The load balancer owns that header, and Cloud
Armor source matching and logging depend on it. A tftest asserts it stays.

**2. The backend still verifies.** Stripping at the edge closes the forgery path; it does not
create an identity. The application validates its own OIDC token on every request. A backend that
trusts a header because "the load balancer strips forgeries" is one URL-map edit away from being
open, and that edit will not look dangerous in review.

---

## What the module builds

| Resource | Purpose |
|---|---|
| `google_compute_security_policy.edge` | Cloud Armor. Default `deny(403)` at priority 2147483647. |
| `google_compute_backend_service.app` | Backend on `var.backend_instance_group`, logging at `sample_rate = 1.0`. |
| `google_compute_health_check.app` | HTTP health check on `var.app_port`. |
| `google_compute_ssl_policy.edge` | `MODERN` profile, `min_tls_version = "TLS_1_2"`. |
| `google_compute_managed_ssl_certificate.edge` | Google-managed cert for `var.hostname`. |
| `google_compute_url_map.https` | Routes to the backend, strips identity headers. |
| `google_compute_target_https_proxy.edge` + forwarding rule | Port 443. |
| `google_compute_url_map.http_redirect` + proxy + forwarding rule | Port 80, **301 redirect only**. |
| `google_dns_record_set.edge` | A record, only when hostname *and* managed zone are both set. |

### Cloud Armor rule layout

| Priority | Rule | Action |
|---|---|---|
| 500 | Preconfigured WAF — SQLi | `deny(403)` |
| 510 | Preconfigured WAF — XSS | `deny(403)` |
| 800 + *n* | Allowlist chunk *n*, rate-limited | `rate_based_ban` |
| 1000 + *n* | Allowlist chunk *n*, fail-safe | `allow` |
| 2147483647 | **Default** | `deny(403)` |

WAF rules sit *above* the allow rules on purpose: an allowlisted source is still not trusted to
send SQL injection. The plain-allow band at 1000 is unreachable while the rate-limited rules
exist, and that is deliberate — the source ranges are identical, so deleting a rate-limit rule
degrades to "allowed but unthrottled" rather than "denied". It can never widen exposure.

Every rule sets `preview = false`. A rule in preview logs its verdict and enforces nothing, which
produces reassuring logs from an open edge.

### The 10-CIDR limit

Cloud Armor caps a single rule's `src_ip_ranges` at 10 CIDRs. This module **chunks** the
allowlist across as many rules as it takes; it never truncates. Truncation would be silent and
asymmetric — the 11th CIDR simply stops working, the operator sees a 403, and the obvious
diagnosis ("the allowlist is wrong") is exactly the wrong one.

`tests/allowlist_chunking.tftest.hcl` supplies 25 CIDRs and asserts the union across the evaluated
rules is 25 distinct entries *equal to the input set*. A count is the only assertion that catches
truncation: "some allow rules were planned" is true whether 25 CIDRs survived or 10 did.

IPv4 and IPv6 chunks share one priority index, so the two families cannot collide.

---

## Fail-closed behaviour

`var.hostname == ""` disables the **entire** public frontend — certificate, SSL policy, both URL
maps, both proxies, both forwarding rules, the global address, and the DNS record. There is no
state in which a forwarding rule exists without the certificate that terminates its TLS.

The Cloud Armor policy and the backend service survive by design: the default deny is the control
that must exist even when nothing is exposed, so that attaching a frontend later cannot
accidentally expose an unprotected backend.

`var.dns_managed_zone == ""` disables only the DNS record; the load balancer stays intact.

An **empty allowlist is legal and is the safe state**: no allow rules are generated and the
default deny is the only rule. An empty list never means "allow everything".

---

## Inputs

| Name | Type | Default | Notes |
|---|---|---|---|
| `project_id` | string | — | e.g. `CHANGEME-project` |
| `environment_key` | string | — | `^(demo\|ci)-[1-9][0-9]*$` |
| `name_prefix` | string | — | `sl-<environment_key>` |
| `labels` | map(string) | — | mandatory label set from the caller |
| `access_mode` | string | `"iap"` | `iap` \| `allowlist` \| `iap_and_allowlist`. The safe posture is the default |
| `iap_members` | list(string) | `[]` | **required non-empty** under any IAP mode; `allUsers`, `allAuthenticatedUsers` and wildcards rejected |
| `iap_oauth2_client_id` | string | `""` | `""` selects the IAP-managed OAuth client |
| `iap_oauth2_client_secret` | string (sensitive) | `""` | set with the id or not at all; never commit a real value |
| `hostname` | string | `""` | `""` disables the whole public frontend |
| `dns_managed_zone` | string | `""` | `""` disables only the DNS record |
| `backend_instance_group` | string | — | `instance_group_self_link` from `modules/compute` |
| `app_port` | number | — | 1–65535 |
| `allowed_ipv4` | list(string) | `[]` | never `0.0.0.0/0`; validated |
| `allowed_ipv6` | list(string) | `[]` | never `::/0`; validated |
| `rate_limit_threshold_per_minute` | number | `600` | finite and positive; no "unlimited" |
| `enable_cdn` | bool | `false` | a cache in front of an authenticated app is a disclosure risk |
| `rate_limit_ban_duration_sec` | number | `600` | additive to CONTRACT §4 — see `NOTES.md` |
| `health_check_path` | string | `"/healthz"` | additive to CONTRACT §4 — see `NOTES.md` |
| `backend_port_name` | string | `"http"` | additive to CONTRACT §4 — see `NOTES.md` |

## Outputs

`lb_ip_address`, `certificate_name`, `security_policy_name`, `backend_service_name`,
`access_mode`, `iap_enabled`, `iap_authorised_member_count`.
The first two are `""` when no public frontend was created. The last three let a caller, a
runbook, or an acceptance test assert the posture it believes it deployed.

---

## Example

```hcl
module "edge" {
  source = "../../modules/edge"

  project_id      = "CHANGEME-project"
  environment_key = "demo-1"
  name_prefix     = "sl-demo-1"
  labels          = local.mandatory_labels["demo-1"]

  hostname         = "demo-1.example.invalid"
  dns_managed_zone = "signalloom-demo"

  backend_instance_group = module.compute.instance_group_self_link
  app_port               = 8080

  # access_mode defaults to "iap" — routable, but not public. Named principals
  # only. Never allUsers or allAuthenticatedUsers: neither is a restriction.
  iap_members = [
    "user:someone@example.invalid",
    "group:demo-viewers@example.invalid",
  ]

  rate_limit_threshold_per_minute = 600
}
```

Defence in depth — IAP *and* a network restriction:

```hcl
module "edge" {
  source = "../../modules/edge"
  # ... as above ...

  access_mode = "iap_and_allowlist"
  iap_members = ["user:someone@example.invalid"]

  # Narrows who can even reach the sign-in page. Exposure control, not
  # authentication: IAP is what establishes who a caller is.
  allowed_ipv4 = ["192.0.2.0/24", "198.51.100.0/24"]
  allowed_ipv6 = ["2001:db8::/32"]
}
```

---

## Testing

```bash
terraform -chdir=terraform/modules/edge init -backend=false
terraform -chdir=terraform/modules/edge test      # 28 runs, offline, mocked providers
bats test/terraform-edge-security.bats            # scripts, absence properties, mutation checks
```

`terraform test` is the primary surface — it asserts on evaluated plan attributes, not on HCL
text. The bats file covers what a plan cannot see: shell behaviour, whole-tree absence, and proof
that the tftest suite can go red (four mutation fixtures under
`test/fixtures/terraform/edge/`, each paired with a baseline-green run).

### Probe scripts

These reach the real internet and are **not** run by CI. Run them by hand after an approved
deployment, from the right network position:

```bash
scripts/gcp-tf/edge-probe-negative.sh demo-1.example.invalid   # unlisted source  -> expect 403
scripts/gcp-tf/edge-probe-positive.sh demo-1.example.invalid   # allowlisted      -> expect 302/401
scripts/gcp-tf/edge-probe-bypass.sh   10.128.0.2 8080          # outside the VPC  -> expect no route
```

Each takes `--dry-run`, which prints exactly what it would do, makes no network request, and
exits 0. The bypass probe's polarity is inverted: a *successful* connection is the failure.
