# Access request — `sl-port-over-sandbox`

**For:** Wendy Overton (`woverton@signal-loom.ai`), project owner
**Requested by:** Andy Martin (`sublimino@gmail.com`)
**Project:** `sl-port-over-sandbox` (number `308545937261`)

Andy currently holds `roles/editor` on this project. Editor turns out **not** to
cover IAM-shaped operations, which is what this request is about. Every
permission below was hit as an actual `403` during a real deploy on
2026-08-18 — none of it is speculative.

There are two independent asks. **Ask 1 is small and unblocks Andy today.**
Ask 2 removes the need to come back to you again.

> **What changed since the first version of this document.** It originally said
> an **organization administrator** had to grant
> `roles/compute.osLoginExternalUser`, because Andy's Google account is external
> to the organization that owns this project and OS Login refuses to configure
> POSIX account data for an external identity without it. That was correct, and
> it was also a dead end: `gcloud organizations list` returns zero items for
> Andy, so he cannot grant it and cannot reach anyone who can without waiting.
>
> **That ask is no longer on the critical path.** A service account created
> *inside* this project is internal to the owning organization by construction,
> so the external-user rule does not apply to it. Andy impersonates that account
> and OS Login works. Measured on 2026-08-18: impersonating
> `sl-tf-deploy@sl-port-over-sandbox.iam.gserviceaccount.com` made the
> `osLoginExternalUser` error disappear entirely and moved the failure to the
> IAP layer (`4033: 'not authorized'`) — which is a **project**-scoped grant, and
> therefore yours to make.
>
> The organization command is still listed below, clearly marked **optional**.
> It is a genuine convenience — with it, Andy can `gcloud compute ssh` as
> himself and skip the impersonation flag — but nothing is blocked without it.

---

## Ask 1 — let Andy reach the demo VM (3 project-scoped commands)

A hardened VM is already deployed: `sl-demo-1-vm` in `us-east4-a`. It has **no
external IP and no public endpoint** — the only way in is Google's
Identity-Aware Proxy, which authenticates the user before any packet reaches the
instance. Andy cannot currently use it because `roles/editor` does not include
IAP tunnel access.

The grants below go to a **dedicated operator service account**, not to Andy
directly. That is what removes the organization dependency, and it is also the
smaller grant: the account can open a tunnel and log in, and can do nothing else
in the project.

```bash
gcloud config set project sl-port-over-sandbox

# 0. Create the operator identity. In-project, and therefore internal to the
#    organization — this is the step that sidesteps roles/compute.osLoginExternalUser.
gcloud iam service-accounts create sl-operator \
  --display-name="Signal Loom demo operator" \
  --description="Reaches demo VMs over IAP and runs the demo pipeline on them. Impersonated, never keyed."

OP="sl-operator@sl-port-over-sandbox.iam.gserviceaccount.com"

# 1. Open an IAP TCP tunnel to instances in this project.
gcloud projects add-iam-policy-binding sl-port-over-sandbox \
  --member="serviceAccount:${OP}" \
  --role="roles/iap.tunnelResourceAccessor" --condition=None

# 2. Log in to the VM via OS Login, with sudo. Sudo is not a nicety: the demo
#    pipeline runs every remote command as `sudo -u ci`, unpacks its work tree
#    with `sudo tar`/`sudo chown`, and installs tools into /usr/local/bin.
#    roles/compute.osLogin (no sudo) cannot run it.
gcloud projects add-iam-policy-binding sl-port-over-sandbox \
  --member="serviceAccount:${OP}" \
  --role="roles/compute.osAdminLogin" --condition=None

# 3. The demo VM carries a non-default runtime service account. OS Login to such
#    an instance requires actAs on that account. Granted ON THE ACCOUNT, not on
#    the project: at project scope this role would cover every service account
#    here, including the Terraform deploy identity.
gcloud iam service-accounts add-iam-policy-binding \
  sl-rt-demo-1@sl-port-over-sandbox.iam.gserviceaccount.com \
  --member="serviceAccount:${OP}" \
  --role="roles/iam.serviceAccountUser"

# 4. Let Andy become the operator account. Impersonation, never a downloaded key.
gcloud iam service-accounts add-iam-policy-binding "${OP}" \
  --member="user:sublimino@gmail.com" \
  --role="roles/iam.serviceAccountTokenCreator"
```

These grants provide no ability to change project IAM or create identities, and
they reach the instance only through an authenticated IAP tunnel. Impersonation
is fully attributable: Cloud Audit Logs record Andy's own address in
`protoPayload.authenticationInfo.principalEmail` alongside
`serviceAccountDelegationInfo`.

This is the same set Terraform declares in
`terraform/modules/operator-identity/`, so running the commands by hand now and
letting Terraform manage it later converge on the same three roles.

### Optional — direct SSH as Andy, no impersonation flag

**Not required. Nothing above depends on it.** If you would like Andy to be able
to run `gcloud compute ssh` as himself rather than as the operator account, an
**organization administrator** must run this. It cannot be granted at project
scope, and it is the one thing in this document that is not yours to action:

```bash
gcloud organizations add-iam-policy-binding ORGANIZATION_ID \
  --member="user:sublimino@gmail.com" \
  --role="roles/compute.osLoginExternalUser"
```

`ORGANIZATION_ID` is the organization that owns `sl-port-over-sandbox`, not
project number `308545937261`. If it is granted, Andy would also need the three
roles above bound to `user:sublimino@gmail.com` as well as to the operator
account. Skip all of that unless someone asks for it.

**Verify it worked** (run as Wendy, read-only):

```bash
# The two project-scoped roles on the operator account.
gcloud projects get-iam-policy sl-port-over-sandbox \
  --flatten="bindings[].members" \
  --filter="bindings.members:sl-operator@sl-port-over-sandbox.iam.gserviceaccount.com" \
  --format="table(bindings.role)"

# The actAs binding, which is on the runtime ACCOUNT and so does not appear above.
gcloud iam service-accounts get-iam-policy \
  sl-rt-demo-1@sl-port-over-sandbox.iam.gserviceaccount.com \
  --format="table(bindings.role,bindings.members)"

# And that Andy can become the operator account.
gcloud iam service-accounts get-iam-policy \
  sl-operator@sl-port-over-sandbox.iam.gserviceaccount.com \
  --format="table(bindings.role,bindings.members)"
```

Expect exactly `roles/iap.tunnelResourceAccessor` and
`roles/compute.osAdminLogin` from the first command. Anything else on that
account is more than was asked for.

---

## Ask 2 — let Terraform finish and tear down the estate

Optional, and strictly larger. Skip it if you would rather keep IAM changes with
yourself; the consequence is that the parts of the estate that create identities
stay unbuilt, and every future teardown/rebuild needs you.

The estate declares 34 distinct resource types. Under `roles/editor` the apply
reached the first IAM-shaped one and stopped, leaving a half-built estate. These
are the four denials observed:

| Denied permission | Needed for |
|---|---|
| `resourcemanager.projects.setIamPolicy` | project IAM bindings, audit-log config |
| `iam.workloadIdentityPools.create` | keyless GitHub CI federation |
| `iam.serviceAccounts.setIamPolicy` | CI impersonation bindings |
| `logging.sinks.create` | the admin-activity audit sink |

### Option 2a — you create the deploy service account (recommended)

This is the smaller long-term grant. You run one bootstrap, and a **dedicated,
least-privilege service account** does every future apply and destroy. Andy never
holds project IAM rights himself; he impersonates the account, and every action
is attributable to him.

```bash
gcloud config set project sl-port-over-sandbox

# Create the deploy identity.
gcloud iam service-accounts create sl-tf-deploy \
  --display-name="Signal Loom Terraform deploy" \
  --description="Applies and destroys the Signal Loom estate. Impersonated, never keyed."

SA="sl-tf-deploy@sl-port-over-sandbox.iam.gserviceaccount.com"

# Roles it needs. Each one is required by a resource type the estate declares.
for ROLE in \
  roles/compute.admin \
  roles/iam.serviceAccountAdmin \
  roles/iam.serviceAccountUser \
  roles/resourcemanager.projectIamAdmin \
  roles/iam.workloadIdentityPoolAdmin \
  roles/logging.configWriter \
  roles/monitoring.editor \
  roles/dns.admin \
  roles/iap.admin
do
  gcloud projects add-iam-policy-binding sl-port-over-sandbox \
    --member="serviceAccount:${SA}" --role="${ROLE}" --condition=None
done

# State-bucket access at BUCKET scope, objectAdmin only: it can read and write
# Terraform state and CANNOT delete the bucket that holds every environment's
# history. This asymmetry is deliberate — please do not "simplify" it to
# roles/storage.admin.
gcloud storage buckets add-iam-policy-binding \
  gs://sl-port-over-sandbox-osramp-tfstate \
  --member="serviceAccount:${SA}" --role="roles/storage.objectAdmin"

# Let Andy become this account. Impersonation, not a downloaded key: a key is a
# bearer credential with no expiry that lives wherever it was last pasted.
gcloud iam service-accounts add-iam-policy-binding "${SA}" \
  --member="user:sublimino@gmail.com" \
  --role="roles/iam.serviceAccountTokenCreator"
```

**Please do not create a JSON key for this account.** Nothing in the estate needs
one, and a guard in the test suite fails if a key resource ever appears.

### Option 2b — grant Andy project IAM admin instead

One command, larger blast radius: `projectIamAdmin` lets the holder grant
themselves anything, so it is functionally equivalent to owner. Option 2a exists
to avoid exactly this.

```bash
gcloud projects add-iam-policy-binding sl-port-over-sandbox \
  --member="user:sublimino@gmail.com" \
  --role="roles/resourcemanager.projectIamAdmin"
```

---

## Unrelated finding, worth 30 seconds of your time

The project's **`default` VPC allows SSH (22), RDP (3389) and ICMP from
`0.0.0.0/0`** — the whole internet. These are Google's auto-created rules, not
anything this project added, and nothing of Andy's uses that network. But any VM
anyone launches into `default` is exposed on creation.

```bash
# Inspect first.
gcloud compute firewall-rules list --project sl-port-over-sandbox \
  --filter="network:default AND sourceRanges:0.0.0.0/0" \
  --format="table(name,allowed[].map().firewall_rule().list())"

# Remove if you agree nothing depends on them.
gcloud compute firewall-rules delete \
  default-allow-ssh default-allow-rdp default-allow-icmp \
  --project sl-port-over-sandbox
```

---

## What Andy will do once Ask 1 lands

```bash
gcloud compute ssh sl-demo-1-vm --zone us-east4-a \
  --project sl-port-over-sandbox --tunnel-through-iap \
  --impersonate-service-account=sl-operator@sl-port-over-sandbox.iam.gserviceaccount.com
```

The `--impersonate-service-account` flag is the whole trick: the tunnel and the
OS Login both happen as the in-project operator account, which the
external-organization rule does not apply to. Without the optional organization
grant, that flag is required on every invocation — which is a mild inconvenience
and not a blocker.

No public IP is created, no firewall is opened, and no port is exposed to the
internet at any point.
