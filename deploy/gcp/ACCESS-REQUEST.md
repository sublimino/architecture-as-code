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

---

## Ask 1 — let Andy reach the demo VM (3 project commands, one organization command)

A hardened VM is already deployed: `sl-demo-1-vm` in `us-east4-a`. It has **no
external IP and no public endpoint** — the only way in is Google's
Identity-Aware Proxy, which authenticates the user before any packet reaches the
instance. Andy cannot currently use it because `roles/editor` does not include
IAP tunnel access.

```bash
# 1. Permit Andy to open an IAP TCP tunnel to instances in this project.
gcloud projects add-iam-policy-binding sl-port-over-sandbox \
  --member="user:sublimino@gmail.com" \
  --role="roles/iap.tunnelResourceAccessor"

# 2. Permit Andy to log in to the VM as an OS Login user with sudo.
#    Use roles/compute.osLogin instead if you would rather he had no sudo.
gcloud projects add-iam-policy-binding sl-port-over-sandbox \
  --member="user:sublimino@gmail.com" \
  --role="roles/compute.osAdminLogin"

# 3. The demo VM uses this non-default runtime service account. Permit Andy to
#    act as it, as required for OS Login to a VM that has a service account.
gcloud iam service-accounts add-iam-policy-binding \
  sl-rt-demo-1@sl-port-over-sandbox.iam.gserviceaccount.com \
  --member="user:sublimino@gmail.com" \
  --role="roles/iam.serviceAccountUser"
```

Because Andy's Google identity is external to the organization that owns this
project, an **organization administrator** must also run this command. It
cannot be granted at project scope. Skip it only if that administrator confirms
`sublimino@gmail.com` is not external to the owning organization:

```bash
gcloud organizations add-iam-policy-binding ORGANIZATION_ID \
  --member="user:sublimino@gmail.com" \
  --role="roles/compute.osLoginExternalUser"
```

`ORGANIZATION_ID` is the organization that owns `sl-port-over-sandbox`, not
project number `308545937261`.

These grants provide no ability to change project IAM or create identities, and
they reach the instance only through an authenticated IAP tunnel.

**Verify it worked** (run as Wendy, read-only):

```bash
gcloud projects get-iam-policy sl-port-over-sandbox \
  --flatten="bindings[].members" \
  --filter="bindings.members:sublimino@gmail.com" \
  --format="table(bindings.role)"
```

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
  --project sl-port-over-sandbox --tunnel-through-iap
```

No public IP is created, no firewall is opened, and no port is exposed to the
internet at any point.
