# Bootstrap State Backend

This root creates and protects the GCS bucket used as the remote backend by the other Terraform roots. It declares no backend block itself, so it is structurally incapable of consuming the bucket it creates.

Apply the roots in this order: bootstrap, then platform, then environments. Bootstrap must run first because it creates the backend the other roots consume, and platform must run before environments because it creates shared identities and controls used by per-environment deployments.

## One-Time Bootstrap Procedure

This procedure is the first and only time this slice creates real GCP resources. Until the final apply step, the commands below validate configuration and prepare local artefacts only.

1. Copy the example variables file to a real, gitignored working file and fill in the `CHANGEME-` placeholders with your values.

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

   This command creates a local working copy only. It does not change Terraform state or GCP resources.

2. Initialise Terraform without a backend.

   ```bash
   terraform init -backend=false
   ```

   This command writes local `.terraform/` metadata only. This root has no remote backend by design.

3. Validate the configuration.

   ```bash
   terraform validate
   ```

   This command changes nothing. It checks the configuration locally.

4. Create a saved execution plan and review it by hand before authorising any resource creation.

   ```bash
   terraform plan -out=tfplan
   ```

   This command writes the local `tfplan` file only. It does not create or modify GCP resources, but the saved plan is the exact action set that a later apply will execute.

5. Apply the reviewed plan.

   ```bash
   terraform apply tfplan
   ```

   This command creates and configures real, billable GCP resources. It is the first destructive or state-changing step against GCP and requires explicit human authorisation.

6. Capture the backend configuration for the downstream roots.

   ```bash
   terraform output -raw backend_config > backend.hcl
   ```

   This command writes the local `backend.hcl` file only. `backend.hcl` is gitignored; `backend.hcl.example` is the committed shape for review.

Bootstrap keeps its own state in a local `terraform.tfstate` file, and that file is gitignored. Losing it does not delete the bucket, but it does make the bucket unmanaged until the state is re-adopted with `terraform import`; that is a recovery path, not part of the normal bootstrap flow.

## The Tailscale auth-key secret

Only needed if any environment sets `tailscale_enabled = true`. Skip this entirely if you are using the IAP fallback.

This secret is not declared by any Terraform root, and neither is its IAM. Both omissions are deliberate and they have different reasons.

**The secret itself** is created out of band because a `google_secret_manager_secret_version` resource carries its payload in `secret_data`, so declaring one would write the auth key into Terraform state in plain text — a GCS object several principals can read. The key would then be readable by more people than the tailnet it admits to. `test/terraform-tailscale-infra.bats` fails if such a resource ever appears anywhere under `terraform/`.

**Its IAM policy** is granted here, once, by the same human, for the same reason `roles/storage.admin` is not granted on the state bucket: creation and IAM are lifecycle, and lifecycle belongs to the privileged bootstrap step rather than to the identity that runs unattended. Declaring the binding in `modules/compute` — where it briefly lived — requires the deploy identity to hold `secretmanager.secrets.setIamPolicy` on the secret, and an identity that can set a secret's policy can grant itself read of that secret. The deploy identity runs from CI. Granting it there would hand back, through the policy door, exactly the access the out-of-band secret was created to withhold.

Run these once per project, as a human who already holds elevated rights. Everything after this is unattended.

```bash
PROJECT=sl-port-over-sandbox
SECRET=sl-demo-tailscale-authkey        # matches tailscale_authkey_secret_id

# 1. The secret, and a version holding a REUSABLE, EPHEMERAL, PRE-APPROVED key
#    minted at https://login.tailscale.com/admin/settings/keys with tag:sl-demo.
gcloud secrets create "$SECRET" --project="$PROJECT" --replication-policy=automatic
printf '%s' 'tskey-auth-…' | gcloud secrets versions add "$SECRET" --project="$PROJECT" --data-file=-

# 2. Each environment's RUNTIME account reads the PAYLOAD. This is the grant the
#    VM uses at boot, under its own attached identity. One per environment key —
#    the accounts are created by terraform/platform, so run this after it.
for ENV in demo-1 demo-2; do
  gcloud secrets add-iam-policy-binding "$SECRET" --project="$PROJECT" \
    --member="serviceAccount:sl-rt-${ENV}@${PROJECT}.iam.gserviceaccount.com" \
    --role=roles/secretmanager.secretAccessor
done

# 3. The DEPLOY account reads the METADATA only. modules/compute looks the secret
#    up with a `data` source so that a missing secret fails at PLAN rather than
#    leaving a VM that silently never joins the tailnet; viewer is what makes
#    that lookup resolve. It answers "does this secret exist" and cannot answer
#    "what is in it".
gcloud secrets add-iam-policy-binding "$SECRET" --project="$PROJECT" \
  --member="serviceAccount:sl-tf-deploy@${PROJECT}.iam.gserviceaccount.com" \
  --role=roles/secretmanager.viewer
```

The asymmetry between steps 2 and 3 is the whole point: the account that applies the estate can prove the key exists and can never read it.

Confirm the result, and note what should NOT be in it:

```bash
gcloud secrets get-iam-policy "$SECRET" --project="$PROJECT"
```

No principal should hold `roles/secretmanager.admin`, `secretVersionManager`, or `secretVersionAdder` — the VM reads one key at boot and never needs to add, rotate, destroy or enumerate anything.

## Why the Real Protection Is IAM

The hard protection on the state bucket is IAM, not configuration flags. `prevent_destroy` and `force_destroy = false` are useful tripwires, but they live in the same configuration that could delete or weaken them, so the same change that destroys the bucket can remove those guards first.

The real control is that no plan or apply principal may hold `roles/storage.admin` on the state bucket. `roles/storage.objectAdmin` is sufficient to read and write Terraform state objects and insufficient to delete the bucket or alter its retention settings. This root grants exactly `roles/storage.objectAdmin` through an authoritative binding and deliberately declares no binding for `roles/storage.admin`, so granting bucket-admin rights would be a visible one-line diff. `test/terraform-state-protection.bats` fails if that line ever appears.

## State Recovery Rehearsal

Rehearse recovery against a scratch prefix or a scratch bucket, never against live platform state. Do it before an incident, not during one, so the first time you discover the process is not when you are already trying to restore production state under pressure.

The rehearsal below treats versioned GCS objects as an operational capability rather than a reassuring checkbox. The state object for a Terraform root lives at `<prefix>/default.tfstate`, and recovery is the act of choosing a prior retained generation deliberately, inspecting it, restoring it, and then confirming from Terraform's point of view that the active state is the one you intended.

```bash
# 1. The state object for a root lives at <prefix>/default.tfstate.
STATE_URL="gs://CHANGEME-osramp-tfstate/osramp/platform/default.tfstate"

# 2. List every retained generation, newest first. Versioning keeps the old ones;
#    this is what the retention lifecycle rule is protecting.
gcloud storage ls --all-versions --long "${STATE_URL}"

# 3. Read the generation numbers and timestamps in a machine-readable form.
gcloud storage objects list "${STATE_URL}" \
  --all-versions \
  --format="table(name, generation, timeCreated, size)"

# 4. Inspect a candidate generation BEFORE restoring it, so the restore is a decision
#    rather than a guess.
gcloud storage cp "${STATE_URL}#CHANGEME-GENERATION" ./candidate.tfstate
terraform show -json ./candidate.tfstate | jq '.values.root_module.resources | length'

# 5. Restore by copying the chosen generation back over the live object. Versioning means
#    the current (bad) state also becomes a retained generation, so this step is itself
#    reversible.
gcloud storage cp "${STATE_URL}#CHANGEME-GENERATION" "${STATE_URL}"

# 6. Confirm the restore took, from Terraform's point of view rather than the bucket's.
terraform state pull | jq '.serial, .lineage'
```

Treat the restore as a controlled state change, not as an exploratory command sequence:

- `gcloud storage cp "${STATE_URL}#CHANGEME-GENERATION" ./candidate.tfstate` creates or overwrites the local `candidate.tfstate` file only so you can inspect the candidate safely before any live change.
- `gcloud storage cp "${STATE_URL}#CHANGEME-GENERATION" "${STATE_URL}"` overwrites the live state object with the selected retained generation. Because object versioning remains enabled, the pre-restore live object becomes another retained generation, so the restore itself is reversible.
- `terraform state pull | jq '.serial, .lineage'` changes nothing. It confirms that Terraform now sees the expected active state lineage and serial.

Two details matter during a real recovery because they are where hurried operators get cut. First, a crashed apply can leave `<prefix>/default.tflock` behind, and every subsequent Terraform command will block on it. `terraform force-unlock CHANGEME-LOCK-ID` releases that lock record, but it must be used only after you have confirmed no other apply is genuinely in flight; forcing a live lock is how two applies end up racing the same state.

Second, `serial` and `lineage` are not bookkeeping trivia. Restoring an older generation moves `serial` backwards, so a later `terraform state push` of a lower serial will be refused unless `-force` is supplied. A `lineage` mismatch is more serious: it means the candidate file belongs to a different state altogether and must not be pushed over the current one. That is a stop-and-think signal, not a flag to override.

## Verification Boundary

Nothing described in this README has been applied from this worktree. The configuration is verified with `terraform fmt`, `terraform init -backend=false`, `terraform validate`, and `tflint` only, and the first apply remains gated on explicit human approval.
