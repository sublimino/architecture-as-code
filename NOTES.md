# F3 — network + compute

Branch `feat/gcp-tf-network-compute`. Owns `terraform/modules/network/**`,
`terraform/modules/compute/**`, `test/terraform-network-security.bats`,
`test/fixtures/terraform/netcompute/**`, this file.

No `terraform apply`, `destroy`, `init` against a real backend, or `gcloud` mutation was run.
Only `terraform fmt`, `terraform init -backend=false`, `terraform validate`, `tflint`, `bats`,
`shellcheck`, and `git` on this branch.

## Verification

| Gate | Result |
|---|---|
| `terraform fmt -recursive -check terraform/` | clean (fixtures also fmt-clean, though they sit outside `terraform/`) |
| `terraform validate` — `modules/network` | Success |
| `terraform validate` — `modules/compute` | Success |
| `tflint --chdir terraform/modules/network` | exit 0 |
| `tflint --chdir terraform/modules/compute` | exit 0 |
| `shellcheck terraform/modules/compute/startup/demo-vm.sh` | exit 0 |
| `bats test/terraform-network-security.bats` | **40/40 pass, 0 fail, 2.1s, offline** |
| `terraform test` — `modules/network` | **13/13 pass** |
| `terraform test` — `modules/compute` | **11/11 pass** |

**Offline proven, not asserted.** All three suites were re-run under `unshare -rn` (empty
network namespace) with `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_CREDENTIALS`,
`GOOGLE_PROJECT`, `CLOUDSDK_CORE_ACCOUNT` and `CLOUDSDK_CORE_PROJECT` unset and both
`CLOUDSDK_CONFIG` and `HOME` pointed at nonexistent paths. Same results — 13, 11, 40. That is
ISC-357 demonstrated rather than claimed.

`.terraform/` and `.terraform.lock.hcl` are removed after each validate run, so
`git status --porcelain` is empty at hand-off. **F1 should add `**/.terraform/` and
`terraform/modules/*/.terraform.lock.hcl` to `terraform/.gitignore`** — I do not own that file.

## Guard falsification — every guard proved able to fail

Three mutation checks run inside the suite (two required, three delivered):

- generated: inject `access_config` into a copy of the live `compute/main.tf` → guard fires
- generated: widen the IAP SSH rule to `0.0.0.0/0` in a copy of `network/main.tf` → guard fires
- generated: append a token literal and a base64 run to a copy of the startup script → fires
- committed fixtures: `broken-access-config.tf`, `broken-wide-firewall.tf` → both caught,
  each with a staleness assertion so "tidying" the fixture fails loudly
- committed fixture: `clean-control.tf` → **negative control**; both scanners return clean,
  which is what distinguishes a working guard from an always-fail one

Sixteen further guards were falsified out-of-band against restored copies (never `git checkout`,
never the real tree left mutated). Every one turned its assertion red, and the tree was verified
clean after each:

| Injected fault | Guard that fired |
|---|---|
| remove the subnet `log_config` | bats: flow logs |
| hardcode the NAT filter | bats: NAT logging |
| line-wrap the egress slogan comment | bats: ISC-91 documentation |
| flip `enable_vtpm` to false | bats: shielded VM |
| default the egress gate open | bats: egress gate defaults closed |
| hardcode the subnet name | bats: contract naming |
| give `deletion_protection` a module default | bats: documented defaults |
| delete `modules/network/tests/` | bats: native suites exist |
| remove `mock_provider "google"` | bats: tftest hygiene |
| switch a run to `command = apply` | bats: tftest hygiene |
| strip every positive `assert` from a file using `expect_failures` | bats: negative/positive pairing |
| add `access_config` to the instance | tftest: private VM |
| hardcode the instance group's named port | tftest: instance group tracks app_port |
| widen `local.iap_range` to `0.0.0.0/0` | tftest: SSH source |
| default `enable_default_deny_egress` false | tftest: egress defaults closed |
| relax the sampling-rate validation to `>= 0` | tftest: rejects a zero sampling rate |

## What the previous (interrupted) run left, and what was wrong with it

The `wip(terraform)` commit's modules were sound and were kept. Its test file was **green while
partly measuring nothing**, which is the exact failure mode the chunk brief names:

1. The flow-log and NAT assertions used fixed `grep -A12` / `grep -A4` windows. The subnet's
   `log_config` sits 13 lines into the block, so the window missed it — the assertion had never
   passed. Both now extract the whole resource block.
2. The credential scanner recursed into the module directories, which after any `terraform
   validate` contain `.terraform/` and `.terraform.lock.hcl` full of legitimate 64-character
   provider digests. It fired on every one. A secrets guard that cries wolf on a clean tree is a
   guard people mute. It now scans git-tracked source files only, with a floor assertion (≥10
   files) and an explicit check that the startup script is in the scanned set.
3. `clean-control.tf` was referenced by a test and by the fixture README but had never been
   written, so the negative control was missing.
4. `main.tf` line-wrapped `"NAT is not egress control"` across two comment lines, silently
   disarming the ISC-91 documentation assertion. The phrase is now on one line with a note
   saying why.
5. A dead `grep -qA4 ... <<<"$(cat ...)" || true` line in the NAT test asserted nothing.

## A contract change landed on this branch mid-chunk

Commit `bbba6c1` ("sync contract + ISA for native terraform tests") was authored into this
worktree **after** I had read CONTRACT.md and started work. It adds §7a and ISC-322..357, making
`.tftest.hcl` the primary correctness surface and bats the secondary one. I picked it up on a
`git log` re-read before hand-off, not at the start — worth the orchestrator knowing that the
window existed. It is implemented in full for both my modules; nothing in the earlier work
needed to be undone, because §7a adds a surface rather than replacing one.

## ISCs claimed

**ISC-76 through ISC-114, ISC-117 through ISC-121** — satisfied and tested.

From the new native-test range: **ISC-326, ISC-327** (suites exist), and this chunk's share of
**ISC-332, ISC-334, ISC-337, ISC-346, ISC-347, ISC-349, ISC-351, ISC-352, ISC-357**. The
whole-tree halves of ISC-333/335/355 and the Make wiring (ISC-353/354) belong to F6 and F7;
my bats guards already sweep every `.tftest.hcl` under `terraform/`, so they will catch a
sibling chunk that omits a `mock_provider` or uses `command = apply` at merge time.

Highlights of how, where it is not obvious:

- **ISC-78** the subnet is named `"${var.name_prefix}-subnet"`, and the contract fixes
  `name_prefix = "sl-${environment_key}"`, so the key is in the name by construction. A test
  asserts every network resource names itself from `var.name_prefix` rather than a literal.
- **ISC-85** every allow rule — ingress *and* egress — sets
  `target_service_accounts = [var.runtime_service_account_email]`. A test walks every exploded
  rule and fails any `allow` block without a target.
- **ISC-107** `confidential_instance_config` is present and driven by
  `var.enable_confidential_compute`, default `false`, with the reason in both the code comment
  and the module README: it constrains the instance to N2D/C2D and forces
  `on_host_maintenance = TERMINATE`, and the estate's default `n2-standard-16` does not support
  it. The module flips `on_host_maintenance` and `automatic_restart` when it is enabled.
- **ISC-114** `preemptible = false` and `provisioning_model = "STANDARD"` are stated explicitly
  rather than left to the provider default, so a later drift toward Spot appears as a diff on a
  line that is about preemptibility.

## ISCs NOT met, with reasons

- **ISC-115** ("`ci-N` instances are separately typed and may be suspended") — **not mine.**
  CI lanes are `terraform/modules/ci-runner`, owned by F5 per CONTRACT §1/§4. `modules/compute`
  is the demo VM only, and creating a file under another chunk's subtree is a merge conflict by
  definition. F5 must satisfy this.
- **ISC-116** — **half mine, and the half I own is done.** `deletion_protection` is a required
  `bool` variable with no module default, and a test asserts it stays undefaulted. The *per-kind
  values* ("true for demo, false for ci") are a root-level decision belonging to
  `terraform/environments` (F2/F6). A module default would let a root forget to pass it and
  still produce a valid plan, which is worse than a required variable.

## The egress decision — read this one

**`enable_default_deny_egress` defaults to `true`. `egress_public_https_destinations` defaults
to `[]`.** With the defaults, an applied environment **cannot pull public container images**,
and the startup script fails at its first download.

That is deliberate. "NAT is not egress control" is a named threat in the proposal: Cloud NAT
gives a private VM outbound reach to the whole internet, and GCP's implied allow-all egress at
priority 65535 means nothing stops it. A variable that defaults open reads as configurable while
behaving as unconstrained — that is precisely how the threat survives review. So the gate
defaults closed and a test asserts it (`the default-deny egress gate defaults closed`), which
means flipping the default is a red build, not a quiet diff.

Explicitly allowed egress, each with a rule behind it and a comment naming it:

| # | Dependency | Rule | Destination |
|---|---|---|---|
| 1 | DNS | `allow_egress_dns` | `169.254.169.254/32`, UDP+TCP 53 — everything else depends on it |
| 2 | Google APIs | `allow_egress_google_apis` | `199.36.153.4/30`, `199.36.153.8/30` TCP 443 — Logging, Monitoring, OS Login lookups, Artifact Registry, via Private Google Access |
| 3 | Intra-subnet | `allow_egress_intra_subnet` | `var.subnet_cidr` — the Kind cluster talking to itself |
| 4 | Public HTTPS | `allow_egress_public_https` | operator-named CIDRs only, `count = 0` when the list is empty |

**Orchestrator decision needed before the first apply:** either resolve the registry ranges into
each environment's tfvars, or set `enable_default_deny_egress = false` for the demo environment
and record why. The second is a worse posture but an explicit one — the plan shows the deny rule
being destroyed. Doing neither means the demo VM bootstraps to a broken state, loudly.

## Contract objections

1. **`modules/compute` needs `app_port`, and CONTRACT §4 does not list it.** The same §4 requires
   `instance_group_self_link`, and the chunk brief requires that group's named port to be
   `var.app_port` — the edge module's backend service resolves the backend by named port, so a
   group without one is unusable. I added `app_port` as a required input rather than hardcoding
   `8080`. **The roots must pass it.** It is already in the environment map, so this is one line
   of wiring, not a new source of truth. Implemented as an addition, not a change — nothing in
   §4 was renamed or removed.

2. **"No firewall rule with `source_ranges` containing `0.0.0.0/0`" cannot be read literally.**
   The same brief requires a default-deny ingress rule, and there is no way to express
   "deny everything not otherwise allowed" without naming `0.0.0.0/0`. A guard that banned the
   string would force the default-deny rules out of the tree — the opposite of the intent. The
   guard is therefore **semantic**: a firewall resource containing both an `allow {` block and
   `0.0.0.0/0` is a violation; one containing `deny {` and `0.0.0.0/0` is the posture working.
   The `clean-control.tf` fixture pins that distinction so nobody "simplifies" it back into a
   string match. Two rules in `modules/network` carry `0.0.0.0/0`, both `deny`.

3. **`labels` cannot be set on networking primitives.** `google_compute_network`, `subnetwork`,
   `router`, `router_nat` and `firewall` accept no `labels` argument in provider ~> 6.8, so
   CONTRACT §3's "every resource sets `labels`" is unimplementable there. The mandatory label set
   is folded into each resource's `description` instead — greppable from `gcloud compute ... list`
   without inventing a second tagging scheme. `modules/compute` sets real `labels` on the
   instance and boot disk, as the contract intends.

## Other things the orchestrator should know

- Two additive optional variables on `modules/network` (`flow_log_aggregation_interval`,
  `flow_log_sampling_rate`) and four on `modules/compute` (`boot_disk_type`, `image_family`,
  `image_project`, `enable_confidential_compute`). All defaulted; a caller wiring against §4
  verbatim needs to set none of them.
- `flow_log_sampling_rate` has a `> 0` validation. A rate of `0` is flow logs that record
  nothing, and "flow logs enabled" would then be a claim rather than a fact. The test asserts the
  validation exists, not just the field.
- The startup script's `fetch_verified` takes the checksum sidecar suffix as an argument:
  `dl.k8s.io` serves `<artifact>.sha256`, the kind releases serve `<artifact>.sha256sum`. The
  previous version hardcoded `.sha256` and would have 404'd on every kind download. It now also
  aborts unless the sidecar parses as a sha256 digest, so a redirect to an HTML error page fails
  closed rather than comparing against garbage.
- No checksum literal is pinned in the script, by choice: a pinned hash goes stale at the next
  version bump and gets deleted rather than updated, which is how download verification quietly
  disappears from a bootstrap script.
- `scripts/ci/gcp-ci.sh` was read, not modified, and none of its resources are imported. Region
  `europe-west2`, IAP-only SSH, and the Cloud Router + NAT design match it. The two things it
  does that this module does not: it scopes no firewall rule to a service account, and it relies
  on the implied allow-all egress.
- The bats suite runs offline in ~2.1s against a 30s budget, and the two `terraform test` suites
  in a few seconds each against a 300s sweep budget, so there is headroom for the integration
  chunk to add cross-module assertions.
- `terraform test` needs `terraform init -backend=false` to have run in the module directory
  first, which is why the Make target must own the init. Running it by hand leaves `.terraform/`
  and `.terraform.lock.hcl` behind; both are removed here before commit.
- The tftest negative runs deliberately use RFC5737 documentation ranges (`192.0.2.0/24`,
  `198.51.100.0/24`) for the public-egress allowlist, and `CHANGEME-project` throughout. One run
  passes `0.0.0.0/0` as an egress destination on purpose — it is the hostile-operator case, and
  the assertions prove the *allow* rules stay pinned regardless.
