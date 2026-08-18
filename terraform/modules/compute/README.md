# `modules/compute`

The Signal Loom demo VM — private, shielded, OS Login only — plus the unmanaged instance
group the edge module's backend service consumes.

## What it creates

| Resource | Notes |
|---|---|
| `google_compute_instance` | No `access_config`, Shielded VM fully on, OS Login enforced, per-environment service account. |
| `google_compute_instance_group` | Unmanaged, wraps the single VM, named port `http` → `var.app_port`. |
| `data.google_compute_image` | Resolves the boot image family to a concrete self-link. |

CI runners are **not** here. They are `modules/ci-runner` (F5), because they are typed
differently: disposable, suspendable, not deletion-protected.

## Inputs

Per `terraform/CONTRACT.md` §4:

| Name | Type | Default |
|---|---|---|
| `project_id`, `environment_key`, `name_prefix`, `labels` | — | — |
| `zone` | string | — |
| `machine_type` | string | `"n2-standard-16"` |
| `boot_disk_gb` | number | `200` |
| `subnet_self_link` | string | — |
| `network_tag` | string | — |
| `service_account_email` | string | — |
| `deletion_protection` | bool | — |
| `startup_script_path` | string | `""` → module's own `startup/demo-vm.sh` |

Additive, all optional, all defaulted:

| Name | Type | Default |
|---|---|---|
| `app_port` | number | — (required; the contract lists it on `modules/network` and `modules/edge`, and the instance group's named port needs it too — see NOTES.md) |
| `boot_disk_type` | string | `"pd-balanced"` |
| `image_family` | string | `"debian-12"` |
| `image_project` | string | `"debian-cloud"` |
| `enable_confidential_compute` | bool | `false` |

## Outputs

`instance_self_link`, `instance_name`, `internal_ip`, `instance_group_self_link`.

## Hardening decisions

**No external IP.** There is no `access_config` block in this module, and
`test/terraform-network-security.bats` asserts none appears anywhere under `terraform/`.
One `access_config` line would give the instance an ephemeral public address and route
around both the load balancer and the network module's egress policy.

**OS Login, enforced.** `enable-oslogin = "TRUE"` moves SSH authorisation into IAM.
`block-project-ssh-keys = "TRUE"` refuses project-wide keys, which would otherwise bypass
OS Login entirely. `serial-port-enable = "FALSE"` closes the out-of-band console path that
ignores the firewall.

**Shielded VM, all three.** Secure boot, vTPM, and integrity monitoring are all `true`.
Two of three is a common half-measure — integrity monitoring without vTPM has nothing to
measure against.

**Confidential Computing, off with a reason.** `confidential_instance_config` is present and
set from `var.enable_confidential_compute`, defaulting `false`. It constrains the instance to
the N2D/C2D machine families and forces `on_host_maintenance = TERMINATE`; the estate's
default `n2-standard-16` does not support it. Turning it on is `enable_confidential_compute
= true` together with a compatible `machine_type` such as `n2d-standard-16` — the module
already flips `on_host_maintenance` and `automatic_restart` to match.

**Service account.** `var.service_account_email` comes from `modules/identity`, one per
environment. A `validation` block rejects anything ending
`-compute@developer.gserviceaccount.com`, so the project's default compute service account —
which carries project-wide Editor in most projects — cannot be attached by accident. Scopes
are `cloud-platform`; legacy scopes are a second, weaker authorisation layer under IAM, and
narrowing there while role bindings stay broad produces a posture nobody can reason about.

**Deletion protection.** Passed in, not decided here. The roots pass `true` for `demo-N` and
`false` for `ci-N`.

**Not preemptible.** `preemptible = false` and `provisioning_model = "STANDARD"` are stated
explicitly rather than left to the default, so a later edit toward Spot instances shows up as
a diff on a line about preemptibility.

**Boot image drift.** `lifecycle.ignore_changes` covers the boot image. The family resolves
to a new self-link every time Google publishes a patched image; without this, the first plan
after any upstream release proposes destroying the demo VM.

## Startup script

`startup/demo-vm.sh`, version-controlled, referenced by path, `shellcheck` clean. It installs
Docker, kind, and kubectl and stops — it does not deploy the demo, because a startup script
that also deploys is one nobody can re-run.

It contains no credential literal, by construction: startup scripts are stored in instance
metadata **in plain text**, readable by anyone holding `compute.instances.get` on the project.
The instance authenticates to Google APIs through its service account via the metadata server.

It also carries no pinned checksum literals — `kind` and `kubectl` are verified against the
publishers' own checksum sidecars. A hash pinned in the script goes stale at the next version
bump and gets deleted rather than updated, which is how download verification quietly
disappears from a bootstrap script. The sidecar suffix is an argument to `fetch_verified`
because the publishers disagree: `dl.k8s.io` serves `<artifact>.sha256`, the kind releases
serve `<artifact>.sha256sum`. Both a 404 on the sidecar and a sidecar that does not parse as a
sha256 digest abort the bootstrap rather than skipping verification.

**With the network module's defaults this script will fail at its first download**, because
public HTTPS egress is denied until an operator names destinations. That failure is
intentional and loud. See `terraform/modules/network/README.md`.
