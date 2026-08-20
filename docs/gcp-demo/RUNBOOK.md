# GCP demo runbook — zero to a browser

From an empty GCP project to the Signal Loom dashboard open in front of you,
then back to nothing. Every command here is real and in order.

The estate is a hardened VM with **no external IP**. There is nothing to browse
to and nothing to SSH to from the open internet. Two access paths exist, and
which one you want is a decision worth making once:

| | **Tailscale** (primary) | **IAP** (fallback) |
| :--- | :--- | :--- |
| Get in with | membership of the tailnet | a Google identity + `roles/iap.tunnelResourceAccessor` |
| `/etc/hosts` edit | none | one line, per machine, forever |
| Certificate | real, issued to the MagicDNS name | self-signed; click through the warning |
| Holds a terminal | no | yes — the tunnel is foreground |
| Works from a phone | yes | no |
| Target | `make gcp-tf-ts-up ENV=demo-1` | `make gcp-tf-public ENV=demo-1` |

**Use Tailscale.** IAP is not deprecated and is not going anywhere — it is fully
tested, and it is the only path that works for someone who cannot join the
tailnet (a client on a customer's laptop, a CI job, an auditor). But every
ergonomic difference above runs the same direction, and the hosts-file line in
particular is the single most common reason a handed-over demo does not open.

Throughout, `ENV` is the environment key — `demo-1`, `demo-2`, `ci-1`. It is
matched against `^(demo|ci)-[1-9][0-9]*$`; `prod-1` is rejected on purpose.

---

## The short version

```bash
export TF_STATE_BUCKET=<your-state-bucket>

make gcp-tf-up      ENV=demo-1     # plan, review, apply, write the hand-off
make gcp-tf-demo-up ENV=demo-1     # deliver the code, build the estate, test it
make gcp-tf-ts-up   ENV=demo-1     # serve it on the tailnet; prints the URL
```

The IAP fallback, if you are not on the tailnet:

```bash
make gcp-tf-public  ENV=demo-1     # publish, prove a 200, print the URL (foreground)
```

Then the teardown, which is not optional — the VM bills until it is gone:

```bash
make gcp-tf-funnel-down ENV=demo-1           # ONLY if you turned Funnel on
make gcp-tf-destroy ENV=demo-1 CONFIRM=demo-1
./scripts/gcp-tf/teardown-verify.sh          # believe the destroy only after this
```

---

## Step 0 — Prerequisites

| Thing | Why | Check |
| :--- | :--- | :--- |
| `gcloud`, `terraform`, `jq`, `tar` | the driver shells out to all four | `command -v gcloud terraform jq tar` |
| An authenticated gcloud | everything below | `gcloud auth list` |
| `deploy/gcp/deploy-sa` | one line, the **Terraform deploy** SA email. Untracked. | `cat deploy/gcp/deploy-sa` |
| A state bucket | Terraform's backend | `make gcp-tf-bootstrap` (below) |

Two service accounts are involved and they are **not** the same thing:

- **deploy SA** — what Terraform impersonates to build the estate. Read from
  `deploy/gcp/deploy-sa`. It holds resource-creation rights.
- **operator SA** — what the *driver* impersonates to SSH and tunnel. Published
  into the hand-off as `operator_sa`, or overridden with
  `GCP_TF_DEMO_OPERATOR_SA`. It holds no creation rights, and it needs
  **`roles/iap.tunnelResourceAccessor`** — without it every tunnel returns
  `4033: 'not authorized'`, which mentions no permission at all.

The driver refuses to fall back from one to the other. See
[Why impersonation, and why it is not the usual reason](#why-impersonation-and-why-it-is-not-the-usual-reason).

---

## Step 0a — One-time Tailscale admin console setup

**None of this is in code and none of it can be.** It is tailnet-level policy,
it is done once ever, and it is done in the admin console by someone with owner
or admin rights on the tailnet. Terraform can create the node; it cannot grant
the node permission to exist.

Skip this section entirely if you are only using the IAP fallback.

| # | Setting | Where | Why it is not optional |
| :--- | :--- | :--- | :--- |
| 1 | `tagOwners` for `tag:sl-demo` | [Access controls](https://login.tailscale.com/admin/acls) | An auth key cannot apply a tag nobody owns. Without this the VM's `tailscale up` is **rejected**, and the node simply never appears — indistinguishable from a VM that failed to boot. |
| 2 | **MagicDNS: on** | [DNS](https://login.tailscale.com/admin/dns) | Without it the node has an IP and no name. No name means no certificate, which means `tailscale serve` has nothing to terminate TLS with and there is no URL to hand over. |
| 3 | **HTTPS Certificates: on** | [DNS](https://login.tailscale.com/admin/dns) | This is what issues the real certificate for `<node>.<tailnet>.ts.net`. Off, `tailscale serve` fails at the certificate step and `gcp-tf-ts-up` reports it as such. |
| 4 | `nodeAttrs` granting `funnel` to `tag:sl-demo` | [Access controls](https://login.tailscale.com/admin/acls) | **Only needed for `gcp-tf-funnel-up`.** Without it the funnel command is refused by policy and the edge will not route. Leaving this off is a perfectly reasonable posture — it makes the public path structurally impossible. |
| 5 | An ACL rule letting *your user* reach `tag:sl-demo` | [Access controls](https://login.tailscale.com/admin/acls) | A node you cannot see and a node that does not exist look identical from `tailscale status`. |

The policy fragments, for reference — merge them into the existing document
rather than replacing it:

```jsonc
{
  "tagOwners": {
    // 1. Who may apply tag:sl-demo. Without this the node cannot join.
    "tag:sl-demo": ["autogroup:admin"],
  },
  "nodeAttrs": [
    // 4. ONLY if you want the public Funnel path. Omit to make it impossible.
    { "target": ["tag:sl-demo"], "attr": ["funnel"] },
  ],
  "acls": [
    // 5. Let your own devices reach the demo node.
    { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:sl-demo:*"] },
  ],
}
```

**The demo node is ephemeral.** It is removed from the tailnet when it goes
down rather than shown as offline, so *an absent node is the expected look of a
suspended demo VM* — not evidence that any of the above is wrong.

On the operator's own machine you need a `tailscale` client, logged into the
same tailnet, brought up **with MagicDNS accepted**:

```bash
tailscale up --accept-dns
tailscale status          # the demo node should be listed
```

A device brought up with `--accept-dns=false` keeps its old resolver and
resolves nothing in the tailnet, while `tailscale status` looks perfectly
healthy. `gcp-tf-ts-up` checks for this before it promises you a URL.

---

## Step 1 — Bootstrap the state bucket (once, ever)

```bash
make gcp-tf-bootstrap
```

This is **plan-only** by design. Applying it creates the bucket every other
root's state lives in — the one action in the estate with no state to roll back
from — so it is not reachable by a one-word target typed absentmindedly. Review
the plan, then apply it by hand:

```bash
terraform -chdir=terraform/bootstrap apply bootstrap.tfplan
```

Record the bucket name; everything below wants it.

```bash
export TF_STATE_BUCKET=<the bucket you just created>
```

---

## Step 2 — Preflight (optional, cheap, worth it)

```bash
./scripts/gcp-tf/preflight.sh
```

Answers "can this apply actually succeed?" before you spend an evening
discovering that it cannot — quota, APIs, IAM, org policy. Read-only by
construction: every cloud call goes through an allowlist of `describe`/`list`
verbs, so it cannot mutate the project it is inspecting.

---

## Step 3 — Plan and apply

The single target, which cannot skip a step:

```bash
make gcp-tf-up ENV=demo-1
```

That runs, in order: `init` + `plan` → render and summarise the saved plan →
`apply` **that exact plan file** → write the hand-off. It refuses to apply a
plan this invocation did not create, because a bare `terraform apply` re-plans
at apply time, so what you read and what Terraform executes are two different
plans.

If you want the steps individually — to review a plan properly, or to re-run one
after fixing one thing:

```bash
make gcp-tf-plan    ENV=demo-1
make gcp-tf-apply   ENV=demo-1
make gcp-tf-handoff ENV=demo-1
```

---

## Step 4 — The hand-off

`make gcp-tf-handoff` writes `deploy/gcp/demo-1.handoff.json`, schema
`signalloom.gcp.handoff/v1`. It is derived entirely from
`terraform output -json` and is **untracked**, because every field in it names a
real project.

```bash
jq . deploy/gcp/demo-1.handoff.json
```

Everything downstream reads this one file and takes no flags. Nothing about the
estate is typed on a command line and nothing is hardcoded in a script.

**Do not hand-write one.** A hand-off with a plausible-looking wrong field
produces a driver that reaches an estate that does not exist and reports on it.

---

## Step 5 — Stand the demo up

```bash
make gcp-tf-demo-up ENV=demo-1
```

What happens, in order:

1. Resume the VM if it is `SUSPENDED` or `TERMINATED`, and wait for SSH.
2. Package this checkout and deliver it over the IAP tunnel.
3. Run `scripts/gcp-tf/demo-pipeline.sh` on the VM — Kind cluster, the full
   Signal Loom estate, the test suite. Its output **streams to your terminal**
   and is also written to `demo-reports/pipeline.log`.
4. Collect the report directory back into `demo-reports/`.
5. Decide PASS / FAIL / ABORTED / STALE and exit accordingly.

Expect this to take a while. The fence is 90 minutes; raise it with
`GCP_TF_DEMO_TIMEOUT_MINUTES=<n>`.

### What is delivered, and why it cannot contain a secret

The payload is `git archive HEAD` — **tracked files only**.

That is a guarantee by construction, not by maintenance. Every piece of secret
material in this repo is gitignored (the tfvars, the hand-offs,
`deploy/gcp/deploy-sa`, `.keys/`), so none of it *can* ride along. The
alternative — a `tar` of the working tree with an `--exclude` list — is a
guarantee only for as long as somebody keeps that list correct, and an
`--exclude` that silently matches nothing looks exactly like one that works.

It is also dramatically smaller. Measured on this repo: a working-tree tar is
**249MB**, because `.terraform*` provider binaries and several `node_modules`
trees survived the excludes. `git archive` is **35MB / ~2576 files**.

The driver still inspects the built artefact and refuses to send it if anything
excluded is present. If that fires, something is *tracked* that must not be —
fix `.gitignore` and untrack it; do not paper over it with an archive exclusion.

**The cost: uncommitted work is not delivered.** `HEAD` is what ships. A run
against a dirty tree would test `HEAD` while you read your edits on disk, and
stamp the report with `HEAD`'s commit — a verdict that is accurate about a tree
nobody is looking at. So a dirty tree is refused:

```
demo-up: REFUSING to deliver — the working tree has uncommitted changes.
```

Commit first, or accept it explicitly with `GCP_TF_DEMO_ALLOW_DIRTY=1`, which
proceeds and tells you plainly that your changes are not in the run.

`git archive` ships no `.git`, and Kustomize needs one as a security boundary
for relative path traversal (`../base/` is rejected without it). The **driver**
`git init`s a throwaway snapshot repo on the VM immediately after unpacking —
this is not left to the pipeline. It is a marker, not history: its SHA is
meaningless, which is why the report is stamped with the commit from **your**
checkout and why a report stamped with anything else is `STALE`.

### Delivery is verified, not assumed

After the transfer the driver reads the payload's size back off the VM and
compares it. This is not padding. `gcloud compute ssh --command '…' < file`
**does not forward stdin**: the command exits 0 and the file lands at **zero
bytes**, and everything downstream reports success against an empty file —
`chmod` works, a launch reports launched, and the log is empty. Nothing anywhere
goes red. An exit status describes the command; only the artefact describes the
artefact.

To re-run just the tests against a cluster that is already standing:

```bash
make gcp-tf-demo-test ENV=demo-1
```

---

## Step 6 — Connect (Tailscale, primary)

```bash
make gcp-tf-ts-up ENV=demo-1
```

That is the whole thing. It prints a URL like
`https://sl-demo-1.<your-tailnet>.ts.net`, and the URL is clickable from any
device already on the tailnet — including a phone — with **no hosts file, no
certificate warning and no terminal held open**. Nothing has to keep running:
close the laptop and the demo stays up.

Before it prints anything it does four checks, in this order and deliberately:

1. **Is there a tailscale client here, and is its daemon up?** Local, free.
2. **Is this environment's node in the tailnet, and is it online?** Local — it
   asks this machine's `tailscaled`, not the cloud. So a suspended VM is
   reported in milliseconds rather than after a minute of `gcloud`.
3. **Does the node's MagicDNS name resolve *on this machine*?** This is the
   direct analogue of the IAP path's `/etc/hosts` check and exists for exactly
   the same reason: the health probe below proves the *dashboard* answers, not
   that a *browser here* can reach it. Without this check the target would print
   "verified before you clicked" and then hand over a URL that fails on the
   click.
4. **Does `/readyz` return a real HTTP 200 at that URL?** Only then is anything
   clickable printed.

### Why there is a `tailscale serve` in the middle

The dashboard is served by an in-cluster Envoy Gateway that routes by **SNI** on
`dashboard.osramp.acme.local`. A request arriving with any other name in the
handshake is closed during TLS — it presents as `UNEXPECTED_EOF_WHILE_READING`,
which reads as a broken tunnel rather than a wrong hostname. So browsing
`https://sl-demo-1.<tailnet>.ts.net:30754` straight at the forwarded port fails
exactly as `https://localhost:30754` does.

`tailscale serve` is what resolves it. The node terminates TLS itself with a
real, publicly-trusted certificate for its MagicDNS name and proxies to a
backend we get to name — so the SNI name is supplied **on the VM**, once,
automatically, instead of on every operator's laptop forever. `gcp-tf-ts-up`
adds `127.0.0.1 dashboard.osramp.acme.local` to the VM's `/etc/hosts` for this.

### The origin changes, and Dex has exactly one issuer

A browser at `https://sl-demo-1.<tailnet>.ts.net` is at a **different origin**
from `https://dashboard.osramp.acme.local:30754`, and Dex pins its OIDC issuer
and callback client to one origin at a time. Left alone the dashboard would load
and the login would bounce — which presents as a *broken application*, not as an
origin mismatch.

So `gcp-tf-ts-up` claims the origin through the shared Dex origin mechanism
(`scripts/lib/dex-origin.sh`) and **refuses if something else is holding it**,
naming the holder. In practice the other holder is an ngrok tunnel from
`make public`. Release that first:

```bash
./scripts/public-tunnel.sh down
```

### Checking on it

```bash
make gcp-tf-ts-status ENV=demo-1
```

Read-only. Reports the node, its MagicDNS name, its tailnet IP, whether it is
online, whether *this machine* resolves it, whether the VM is publishing, who
currently holds the Dex origin, and whether `/readyz` answers.

---

## Step 6a — Tailscale Funnel: the public internet

```bash
make gcp-tf-funnel-up   ENV=demo-1     # ON
make gcp-tf-funnel-down ENV=demo-1     # OFF
```

**Read this paragraph before running it.** Funnel is the only thing in this
entire estate that creates a listener the public internet can reach. Everything
else is closed by construction: the VM has no external IP, IAP requires a Google
identity holding `roles/iap.tunnelResourceAccessor`, and Tailscale requires
membership of this tailnet. Funnel routes the node's MagicDNS name through
Tailscale's edge, under a valid public certificate, to anyone who has the URL.

Behind it is a demo estate with **published credentials**
(`demo-user@signalloom.local` / `demo-user`). Treat everything in it as
disclosed for as long as Funnel is on.

**It does not expire.** Nothing switches it off for you, and
`make gcp-tf-destroy` is the only other thing that ends it. Turn it off when the
demo ends.

Funnel serves the *same URL* as `gcp-tf-ts-up` — `serve` and `funnel` publish
the same name with the same certificate, and funnel only adds public
reachability. That is why `funnel-up` does not re-patch Dex (the origin is
identical) and why `funnel-down` leaves the tailnet demo standing: after
switching the public listener off, the demo is still live for the tailnet at the
same address.

---

## Step 6b — Connect (IAP, the fallback)

Use this when you cannot join the tailnet. It is fully supported and fully
tested; it is second because of the hosts file and the foreground tunnel, not
because it is less reliable.

```bash
make gcp-tf-public  ENV=demo-1     # publish, prove a 200, then print the URL
make gcp-tf-connect ENV=demo-1     # tunnel only — proves the port binds, nothing more
```

`gcp-tf-public` is the one to use. `gcp-tf-connect` proves the local port
*binds*, which is not the same as a demo that works: gcloud binds locally before
it has proven anything about the far side, and the VM-side `kubectl
port-forward` is the piece that actually dies.

Both open `gcloud compute start-iap-tunnel <instance> 30754
--local-host-port=localhost:30754` in the **foreground** and print everything
you need first. Ctrl-C closes it.

### What you have to do

**1. Add the hosts entry** (once per machine):

```
127.0.0.1 dashboard.osramp.acme.local
```

The dashboard is served by the Envoy Gateway behind an **SNI hostname**.
`https://localhost:30754` reaches the Gateway and is then rejected at TLS,
because the name in the request is not the name the certificate and the route
are keyed on.

**2. Accept the certificate.** It is self-signed. There is no public CA in this
estate and there is not meant to be.

**3. Open** <https://dashboard.osramp.acme.local:30754>

**4. Log in through Dex:**

```
username: demo-user@signalloom.local
password: demo-user
```

### Confirm the tunnel before opening a browser

```bash
curl -k --resolve dashboard.osramp.acme.local:30754:127.0.0.1 \
  https://dashboard.osramp.acme.local:30754/readyz
```

`ready` means the estate is up. A hang means the tunnel is not bound. A
connection that 404s means the tunnel is fine and the estate is not — which is a
completely different problem and a completely different fix.

### Port 30754 is not negotiable

Dex pins its OIDC issuer **and** its callback client to it — see
`scripts/acceptance-test.sh`, function `setup_gateway_forward`. On any other
local port the dashboard loads, the login redirect fails, and the result
presents as a *broken application* rather than as a port mismatch. That costs an
hour aimed at the wrong layer, so `gcp-tf-connect` refuses to open a different
port rather than letting you find out. `GCP_TF_DEMO_ALLOW_PORT_MISMATCH=1`
overrides it if you genuinely mean to.

---

## Step 7 — Tear down

The VM bills until it is gone. `gcp-tf-demo-up` leaves it **running** on a
failure so it can be inspected — that is deliberate, and it is your job to close
it out.

Suspend it (keeps the disk, resumes fast, still costs storage):

```bash
gcloud compute instances suspend <instance> --zone=<zone> --project=<project> \
  --impersonate-service-account=<operator-sa>
```

Or destroy the environment outright:

```bash
make gcp-tf-destroy ENV=demo-1 CONFIRM=demo-1
```

`CONFIRM` must be typed and must match `ENV`. Typing the key is the point: it is
the step that fails when you meant `demo-2` and your shell history said
`demo-1`.

Then verify it, and believe the destroy only once this passes:

```bash
./scripts/gcp-tf/teardown-verify.sh
```

`terraform destroy` reporting success means Terraform removed everything *it*
knows about. That is a narrower claim than "the environment is gone", and the
gap between the two is where the bill comes from.

---

## Failure modes, and how to tell them apart

The four verdicts are not interchangeable and the exit codes carry them.

| Verdict | Exit | What it means | First move |
| :--- | :--- | :--- | :--- |
| `PASS` | 0 | tests ran, all green | `make gcp-tf-connect ENV=…` |
| `FAIL` | pipeline's own, or 1 | tests ran, some failed | read `demo-reports/summary.json` |
| `ABORTED` | pipeline's own, or 2 | **no verdict was produced** | read `demo-reports/pipeline.log` |
| `STALE` | as ABORTED | the report describes a *different* run | re-run; do not read the report |

**`ABORTED` is worse than `FAIL`, not better.** It means the pipeline never
reached the test stages, so nothing was measured. A missing summary is never
read as a pass — that exact ambiguity was read as a pass twice in one day on
2026-08-13, which is why this table exists and why the classifier has four
answers rather than two.

The verdict is always on disk at `demo-reports/summary.json`, stamped with the
branch and commit it describes. Read that file, not the VM's state — suspending
is what a pass looks like *and* what a manual cleanup looks like.

### Tailscale path — the five things that go wrong

Every row below is a state `gcp-tf-ts-up` and `gcp-tf-funnel-up` distinguish and
report separately, because the fixes have nothing to do with each other and a
single "Tailscale is not working" message sends the reader to the admin console
for a missing package.

| Symptom | What it actually is | Fix | Exit |
| :--- | :--- | :--- | :--- |
| `no node named 'sl-demo-1' in this tailnet` | The node is **absent**, not offline. Three causes, indistinguishable from your machine: the VM is down (the node is ephemeral, so it is *removed*, not shown offline); the auth key expired or `tag:sl-demo` has no `tagOwners` entry so it was never approved; or an ACL hides it from you. The message lists the nodes you *can* see, which is the one piece of evidence available locally. | `make gcp-tf-demo-status ENV=…` first — if the VM is suspended, that is the whole answer. Otherwise [Step 0a](#step-0a--one-time-tailscale-admin-console-setup) rows 1 and 5. | 2 |
| `node '…' is in the tailnet but OFFLINE` | The node is **known by name and not answering**. Not a resolution problem and not an ACL problem — those would present as the row above. The VM is suspended or its `tailscaled` is not running. | `make gcp-tf-demo-up ENV=…` | 2 |
| `node '…' has no MagicDNS name` | MagicDNS is off for the **tailnet**. The node has an IP and no name, so no certificate can be issued and there is no URL to hand over. | [Step 0a](#step-0a--one-time-tailscale-admin-console-setup) row 2 | 2 |
| `… does not resolve on this machine` | The node is up and named; **your device** is not using the tailnet's resolver. Usually `tailscale up --accept-dns=false`, occasionally something local rewriting `/etc/resolv.conf` after `tailscaled` wrote it. `tailscale status` looks healthy throughout. | `tailscale up --accept-dns`. For a scripted probe with no browser: `GCP_TF_DEMO_SKIP_MAGICDNS_CHECK=1` | 4 |
| `REFUSING — another origin already holds Dex` | Something else — almost always an ngrok tunnel from `make public` — owns Dex's single OIDC issuer. Taking it would break that demo's login without warning it. The message names the holder. | `./scripts/public-tunnel.sh down`, then re-run | 6 |
| `needs the Dex origin mechanism, and it is not in this checkout` | `scripts/lib/dex-origin.sh` is missing. Serving a new origin without it gives you a dashboard that **loads** and a login that **bounces**. | Use `make gcp-tf-public ENV=…`, which serves at the origin Dex is already pinned to. `GCP_TF_DEMO_SKIP_DEX_ORIGIN=1` proceeds anyway for `ts-up` only — never for `funnel-up`. | 5 |
| `'tailscale serve' failed` mentioning a certificate | HTTPS Certificates are off for the tailnet. | [Step 0a](#step-0a--one-time-tailscale-admin-console-setup) row 3 | 2 |
| `'tailscale funnel' failed` / an empty status behind Funnel | The tailnet policy grants no `funnel` `nodeAttr` to `tag:sl-demo`, so the edge refuses to route. | [Step 0a](#step-0a--one-time-tailscale-admin-console-setup) row 4 | 2 |
| `the node is up but the dashboard did not answer /readyz` | Got far enough to ask, so MagicDNS and the tailnet are fine. **Empty** status → the certificate did not verify (row 3). **502** → `serve` reached the VM-side forward and got nothing; the estate is down. **404** → the Gateway answered and no route matched the SNI name; the VM's loopback alias is wrong. | Follow the status code, not the symptom | 3 |

**`gcp-tf-funnel-down` is not covered by teardown-verify.** If `funnel-down`
fails it says so loudly and tells you the public listener **may still be up** —
that is not a formality. Check by hand before walking away:

```bash
gcloud compute ssh <instance> --zone=<zone> --project=<project> \
  --impersonate-service-account=<operator-sa> --tunnel-through-iap \
  --command='sudo tailscale funnel status'
```

`make gcp-tf-destroy` also ends it, by destroying the node.

### `demo-up: no hand-off for ENV=demo-1`

You have not run `make gcp-tf-handoff ENV=demo-1`, or you are in a different
checkout from the one that produced it (it is untracked, so it does not travel).
Regenerate it. Do not hand-write one.

### `agent refused operation`, or an IAP SSH that "times out"

A populated `ssh-agent` breaks IAP SSH. This reads as a VM provisioning fault
and is a purely local one — on 2026-08-03 it cost ten minutes pointed at a VM
that had finished provisioning in 124 seconds.

`demo-up.sh` empties `SSH_AUTH_SOCK` on every path, so if you see this it came
from an **ad-hoc** `gcloud compute ssh` you typed yourself. Prefix it:

```bash
SSH_AUTH_SOCK= gcloud compute ssh ...
```

### `roles/compute.osLoginExternalUser` / permission denied on SSH

You are reaching the cloud as yourself instead of as the operator SA. The fix is
**not** to grant yourself the role — you cannot. The operator is external to the
owning organisation, and `gcloud organizations list` returns zero items for
them, so there is no org-level policy they can edit. Use the impersonation path;
that is what it is for. An org admin granting the role is an optional
convenience, never a prerequisite.

### `4033: 'not authorized'` when opening the tunnel

The full form is `ERROR: [0] Error during local connection to [stdin]: Error
while connecting [4033: 'not authorized']`. It mentions no permission and no
principal, and reads like a network fault. **It is IAM.** The operator service
account needs `roles/iap.tunnelResourceAccessor`:

```bash
gcloud projects add-iam-policy-binding <project> \
  --member=serviceAccount:<operator-sa> \
  --role=roles/iap.tunnelResourceAccessor
```

There is roughly a **minute of propagation delay**. An immediate retry after
granting still fails, which reads exactly like the grant not having worked.
Wait, then retry.

### `4003: 'failed to connect to backend'` when opening the tunnel

Two causes wearing one error, indistinguishable from the client:

1. **Nothing is listening** on the target port. Check the estate is up:
   `make gcp-tf-demo-status ENV=demo-1`.
2. **A firewall rule does not permit it.** The IAP source range is
   `35.235.240.0/20`. A rule set that opens `tcp:22` from that range and opens
   `app_port` only to Google's load-balancer health-check ranges produces
   exactly this, because there is no load balancer in front of this environment.

```bash
gcloud compute firewall-rules list --project=<project> \
  --format='table(name,allowed[],sourceRanges[])'
```

`gcp-tf-connect` does not hang on either. It polls the local port to a deadline,
then kills the tunnel and prints the diagnosis with gcloud's own stderr.

### `Docker daemon is not running` — when it is running

`install-ci-tools.sh` and `setup.sh --tools-only` both abort with this on a
fresh VM while the daemon is up and healthy. The message names the wrong cause:
**the OS Login user is not in the `docker` group**. Confirm with `id` and
`sudo systemctl status docker` before believing the message.

### `the payload is not on <instance>` / `delivered payload is N bytes and M were sent`

The transfer reported success and the bytes did not arrive, or arrived
truncated. Do **not** read the run that would have followed as a result about
your code — nothing, or only part of it, was delivered. Retry; if it repeats,
the tunnel or the VM's disk is the place to look, not the pipeline.

### `gcloud is not authenticated, so <instance>'s state is UNKNOWN`

An unreadable state is **not** an absent VM. Do not re-apply Terraform on this
basis; you would be building a duplicate estate. Run `gcloud auth login`.

### `REFUSING to open the tunnel on port <n>`

The hand-off's `app_port` is not the Dex-pinned 30754. Fix the estate, not the
tunnel — see [Port 30754 is not negotiable](#port-30754-is-not-negotiable).

### The dashboard loads and the login bounces

Almost always the port. Check the tunnel is on 30754 at *both* ends, and that
your `/etc/hosts` line is present. The application is fine.

### `backend prefix mismatch — this is CONTRACT §5a firing`

Terraform was about to write one environment's resources into another's state.
Re-run `terraform init -reconfigure`, and work out how the data dir got crossed
before you do anything else.

---

## Why impersonation, and why it is not the usual reason

Everywhere else in this estate impersonation exists because the human's own
principal is `roles/editor`, which can create a VPC and a VM and cannot create
the IAM-shaped resources — so a direct apply gets a long way in and then dies,
leaving a half-built estate and inviting the wrong fix.

For the **demo driver** the reason is different. The operator is EXTERNAL to the
owning organisation, so `gcloud compute ssh` requires
`roles/compute.osLoginExternalUser` — a role an external principal cannot grant
itself. The error names an OS Login permission, so the diagnosis it invites is
"grant that role", which is not an action you have the authority to take. An
org-internal service account is not subject to the rule at all, so every gcloud
call the driver makes carries `--impersonate-service-account`.

This is measured, not theoretical.

---

## The pipeline contract

`demo-up.sh` (local) and `scripts/gcp-tf/demo-pipeline.sh` (on the VM) are two
halves of one thing. The interface, so neither can drift silently:

**Invocation** — `bash scripts/gcp-tf/demo-pipeline.sh`, with the working
directory set to `SL_DEMO_WORK_DIR`, under `bash -l`. It runs as the **OS Login
user** unless `GCP_TF_DEMO_REMOTE_USER` names a service account to drop to;
`sudo -u` naming an account that does not exist fails with a message about sudo,
which reads as a privilege problem rather than a wrong assumption.

**What the driver has already done before the pipeline starts** — so chunk C
does not repeat it: the checkout is unpacked at `SL_DEMO_WORK_DIR`, owned by the
invoking user, and a throwaway `git init` + snapshot commit exists there for
Kustomize's path-traversal boundary. The pipeline does **not** need to create
one. It **does** need to mint its own signing material: `.keys/` is gitignored
and therefore not in the payload, by construction.

**Configuration** — environment only, no arguments:

| Variable | Meaning |
| :--- | :--- |
| `SL_DEMO_ENV` | environment key, e.g. `demo-1` |
| `SL_DEMO_STAGE` | `full` (build the estate, then test) or `test` (tests only) |
| `SL_DEMO_WORK_DIR` | absolute path of the delivered checkout |
| `SL_DEMO_REPORT_DIR` | absolute directory to write reports into |
| `SL_DEMO_SUMMARY_FILE` | absolute path of the JSON verdict file |
| `SL_DEMO_APP_PORT` | port to serve the UI on (30754) |
| `SL_DEMO_HOSTNAME` | dashboard SNI name (`dashboard.osramp.acme.local`) |
| `SL_DEMO_LOG` | absolute path of the pipeline log on the VM |
| `SL_DEMO_SOURCE_COMMIT` | short SHA of the **local** checkout |
| `SL_DEMO_SOURCE_BRANCH` | branch of the local checkout |

**Output** — `SL_DEMO_SUMMARY_FILE`, a JSON object carrying at least:

```json
{ "outcome": "PASS", "commit": "<SL_DEMO_SOURCE_COMMIT>" }
```

`outcome` is one of `PASS`, `FAIL`, `ABORTED`. `commit` **must** be the
`SL_DEMO_SOURCE_COMMIT` it was handed — the VM's own git SHA belongs to a
throwaway snapshot repo and stamping that instead makes every run read as
`STALE`.

**Exit status** — 0 for pass, non-zero otherwise. A zero exit with no summary is
treated as `ABORTED`, never as a pass.

---

## Environment overrides

Every external dependency of the driver is injectable, which is what makes
`test/terraform-demo-driver.bats` able to exercise the whole control flow
against stubs with no cloud access.

| Variable | Default | Use |
| :--- | :--- | :--- |
| `GCP_TF_DEMO_OPERATOR_SA` | from the hand-off | override the SSH identity |
| `GCP_TF_DEMO_TIMEOUT_MINUTES` | `90` | raise the pipeline fence |
| `GCP_TF_DEMO_REPORT_DIR` | `demo-reports/` | where reports land locally |
| `GCP_TF_DEMO_REMOTE_DIR` | `/opt/signalloom/repo` | delivery target on the VM |
| `GCP_TF_DEMO_REMOTE_USER` | *(empty)* | service account to drop to on the VM; empty means the OS Login user |
| `GCP_TF_DEMO_ALLOW_DIRTY` | `0` | deliver `HEAD` despite uncommitted changes |
| `GCP_TF_DEMO_ALLOW_PORT_MISMATCH` | `0` | open a non-Dex port anyway |
| `GCP_TF_DEMO_TUNNEL_WAIT_SECONDS` | `20` | how long to wait for the tunnel to bind before diagnosing |
| `GCP_TF_DEMO_PORT_PROBE` | built-in | how the tunnel's local port is tested |
| `GCP_TF_DEMO_GCLOUD` | `gcloud` | the gcloud binary, plus flags |
| `GCP_TF_HANDOFF_DIR` | `deploy/gcp` | where hand-offs are read from |

Tailscale path:

| Variable | Default | Use |
| :--- | :--- | :--- |
| `GCP_TF_DEMO_TAILSCALE` | `tailscale` | the local tailscale binary |
| `GCP_TF_DEMO_TS_HOSTNAME` | hand-off `tailscale_hostname`, else `sl-<env>` | the node's short hostname |
| `GCP_TF_DEMO_SKIP_MAGICDNS_CHECK` | `0` | proceed when this machine cannot resolve the node — scripted use only, a browser will still fail |
| `GCP_TF_DEMO_SKIP_DEX_ORIGIN` | `0` | do not repoint Dex. **`ts-up` only**; the login will bounce |
| `GCP_TF_DEMO_DEX_ORIGIN_CMD` | *(empty — run it on the VM)* | a local command implementing the origin interface |
| `GCP_TF_DEMO_DEX_ORIGIN_REL` | `scripts/lib/dex-origin.sh` | where the origin mechanism lives in the checkout |
| `GCP_TF_DEMO_TS_SERVE_PORT` | `443` | the port `serve`/`funnel` listen on |
| `GCP_TF_DEMO_TS_HEALTH_PATH` | `/readyz` | the readiness endpoint probed over MagicDNS |

---

## Read next

| File | Why |
| :--- | :--- |
| `deploy/gcp/README.md` | the estate's own documentation |
| `terraform/CONTRACT.md` | what the Terraform roots guarantee |
| `scripts/ci/README.md` | the *other* GCP lane (CI VMs), and its traps |
| `test/terraform-demo-driver.bats` | what the IAP lane is actually proven to do |
| `test/terraform-tailscale-access.bats` | what the Tailscale lane is actually proven to do |
