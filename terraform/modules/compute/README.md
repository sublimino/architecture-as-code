# `modules/compute`

The Signal Loom lane VM — private, shielded, OS Login only — plus the unmanaged instance
group the edge module's backend service consumes.

**One module, two lane kinds.** Demo lanes and CI lanes are both built here.

## What it creates

| Resource | Notes |
|---|---|
| `google_compute_instance` | No `access_config`, Shielded VM fully on, OS Login enforced, per-environment service account. Named `sl-<key>-vm` for both kinds. |
| `google_compute_instance_group` | Unmanaged, wraps the single VM, named port `http` → `var.app_port`. |
| `data.google_compute_image` | Resolves the boot image family to a concrete self-link. |

## CI lanes used to be a separate module, and merging them was a bug fix

`modules/ci-runner` built CI lanes until 2026-08-20. The two modules were the same machine —
identical shielded config, OS Login, blocked project keys, cloud-platform scope, scheduling,
pd-balanced boot disk, subnet and network tag — with one difference that mattered:

**`modules/ci-runner` had no `metadata_startup_script` at all.** A CI lane booted a bare box.
Every fix to the demo bring-up landed on a machine CI never ran, so CI was green against
something that was not the demo. That is the whole argument for the merge; tidiness is not.

A CI lane is now a demo lane that additionally:

* carries the `ci-lane = <key>` label, which `scripts/ci/gcp-tf-reaper.sh` **selects on**;
* publishes `idle-suspend-minutes` as instance metadata, so the reaper reads the budget off
  the instance rather than carrying a duplicate constant;
* is not deletion-protected — a lane that cannot be deleted outlives the branch that needed
  it and quietly bills.

### The `ci-lane` label is a safety interface

The reaper SUSPENDS instances and this module is the only thing that emits the label it
selects on. Before the merge, the reaper's protection against touching a demo VM was the
instance NAME shape `sl-<key>-runner`; unified names made that gate match nothing, which would
have been a silent no-op reported as success.

So the label's presence is a *checked* property rather than a convention. Three preconditions
require `var.kind`, the env-contract `kind` label and the environment key's prefix to agree
before the plan proceeds — all three derive from one tfvars entry, so agreement is free when
the wiring is right and impossible when it is not.

## Inputs

Per `terraform/CONTRACT.md` §4:

| Name | Type | Default |
|---|---|---|
| `project_id`, `environment_key`, `name_prefix`, `labels` | — | — |
| `kind` | string | **none** — see below |
| `zone` | string | — |
| `machine_type` | string | `"n2-standard-16"` |
| `boot_disk_gb` | number | `200` |
| `subnet_self_link` | string | — |
| `network_tag` | string | — |
| `service_account_email` | string | — |
| `deletion_protection` | bool | — |
| `startup_script_path` | string | `""` → module's own `startup/demo-vm.sh` |
| `idle_suspend_minutes` | number | `0` (disabled — the demo answer; CI lanes must pass ≥ 5) |

### Why `kind` has no default

Both possible defaults fail open, in opposite directions.

`"demo"` means a CI lane whose caller forgot the input plans and applies perfectly, carries no
`ci-lane` label, and is invisible to the reaper forever. The reaper reports "0 suspended" and
is telling the truth. Nothing errors; the only signal is the invoice.

`"ci"` means a demo VM acquires the label a suspend script selects on.

There is no safe default, so the caller must say which it is. `kind` is already a field of the
frozen environment object, so this adds no new concept — it stops the module guessing.

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

## Docker socket access, and the error message that lies

The startup script installs Docker; it cannot add the logged-in user to the `docker` group,
because this VM enforces OS Login and the account does not exist yet. OS Login provisions
`sa_<numeric-id>` (service account) or `<user>_<domain>` (human) at **first login**, strictly
later than a startup script. A `usermod` naming a fixed user here would match nobody and
succeed silently — `scripts/ci/vm-startup.sh` gets away with exactly that line only because
the v1 CI VM creates a fixed local `ci` user and does not use OS Login.

Measured on a freshly replaced `sl-demo-1-vm`:

```
$ systemctl is-active docker    -> active
$ id -nG                        -> sa_102755196918063701885 video
$ docker info
permission denied while trying to connect to the docker API at unix:///var/run/docker.sock
```

**Read the next paragraph before you restart anything.** `scripts/ci/install-ci-tools.sh` then
exits 1 with `ERROR: Docker daemon is not running`, and `scripts/setup.sh --tools-only` with
`the docker daemon is not running; start it and rerun`.
**Both of those messages are wrong about the cause.**
The daemon is up, enabled and healthy; the caller cannot open its socket. Restarting Docker
changes nothing and costs a bring-up.

(That sentence is kept on one line on purpose. `terraform-vm-profile.bats` greps for it, and a
line-wrapped warning is a documented decision that silently stops being one — the same trap
`modules/network/main.tf` records against its own "NAT is not egress control" slogan.)

Two mechanisms address it, neither of which widens the socket:

1. **`/etc/default/instance_configs.cfg`** — puts newly provisioned OS Login accounts in
   `docker`. Applied at account creation, so the user's first shell already has the group. No
   relogin race, no permission change.
2. **`/etc/profile.d/99-signalloom-docker-group.sh`** — the backstop, for when the guest agent
   did not apply the group. It `usermod`s the current user and says plainly on the terminal
   that **the membership applies to the next session**. A login that falls back to this will
   see the socket error once and succeed after reconnecting.

Setting `SocketMode=0666` on `docker.socket` would remove the relogin caveat and was rejected.
Docker socket access is root-equivalent — write access is enough to start a privileged
container that mounts the host filesystem — so `0666` grants root to every local account,
including an OS Login principal holding plain `roles/compute.osLogin` and no sudo. On an
environment whose demonstration subject is security posture, that is the first thing a hostile
reviewer would find, and it buys nothing the two mechanisms above do not already provide.

## Tailscale

Off unless `tailscale_enabled = true`. With it false the module plans **no** data source, **no**
IAM binding and **no** `signalloom-tailscale-*` metadata key — a disabled instance's metadata is
byte-identical to what it was before this feature existed. That matters because the auth-key
secret is created **out of band**, so an environment that has not been given one must still plan
and apply cleanly.

### The auth key is never in metadata, and never in state

Startup scripts **are** instance metadata: stored in plain text, readable by anyone holding
`compute.instances.get` on the project. So the key is not in the script and not in the metadata.
What travels there is the **name** of the secret; the VM resolves that name at boot, over the
metadata server, using a token minted for its own attached service account.

The secret is also not a Terraform `resource`. `google_secret_manager_secret_version` carries its
payload in `secret_data`, which would write the key into Terraform state in plain text — a GCS
object several principals can read. A `data` source instead gives the one thing worth having at
plan time: an enabled environment whose secret is missing fails at **plan**, rather than applying
and leaving a VM that silently never joins the tailnet.

### The grant is one role on one secret

`google_secret_manager_secret_iam_member` binds on a single secret.
`google_project_iam_member` with the same role would grant read on **every** secret in the
project, present and future, to a service account attached to a VM that pulls public container
images. The two lines look almost identical in a diff and differ by the whole blast radius of the
project's secret store. `test/terraform-tailscale-access.bats` pins the module's IAM budget at
exactly one resource of exactly that type.

### Two decisions worth knowing before changing them

**`tailscale_ssh_enabled` defaults to false.** Tailscale SSH is genuinely good — no key
distribution, no sshd configuration, authorisation as a per-connection ACL rule. It is off here
because it adds a **second authorisation system that GCP IAM and the GCP audit log cannot see**:
a principal denied by OS Login can still be admitted by the tailnet ACL, and nothing in
`gcloud compute instances describe` says so. On an environment whose subject is the posture, that
is a bad default. It is a default, not a prohibition — set it in a tfvars someone reads. Note the
asymmetry that makes false cheap: the tailnet still reaches the application on `app_port`, which
is the thing that was wanted; only the shell falls back to IAP, and IAP for a shell already works.

**`tailscale up --accept-dns=false` is load-bearing.** Accepting MagicDNS rewrites
`/etc/resolv.conf`. This VM's resolver is the metadata server, and the VPC private zone is what
points `googleapis.com` at the restricted Private Google Access VIP. Replace the resolver and
`googleapis.com` resolves publicly, at which point the deny-all egress rule correctly refuses the
public address and the estate fails with `dial tcp 172.217.x.x:443: i/o timeout` — a failure that
reads as an over-strict firewall and has nothing to do with the firewall.

### It cannot stop the VM booting

Every failure path in the startup script's Tailscale stage logs a `WARNING` and continues: a
missing secret, an unreadable one, a denied `pkgs.tailscale.com`, a failed `tailscale up`. A VM
that will not boot because an optional feature's secret is missing is strictly worse than a VM
without the feature, and nothing in the estate's bring-up depends on the tailnet. `die` appears
nowhere in that code path, and the bats suite asserts it.
