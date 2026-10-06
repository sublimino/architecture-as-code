# Runbook — SLAWS live collector lab

> SLAWS v2 §9, D5, D12, D13. Owner: Signal Loom platform.
> Code: `infra/aws/slaws-lab/`, `scripts/slaws-live-lab.sh`.

## What this is for

The SLAWS live lab provides an automated, reproducible procedure to validate
the live AWS collector (`COLLECTOR_AWSLOGS_MODE=live`) against real AWS infrastructure
without changing any in-tree deployment manifest (D13).

The lab provisions:
1. **Read-only cross-account role** matching [`docs/signalloom/slaws-kusari-trust-policy.md`](../slaws-kusari-trust-policy.md)
   with enforced `sts:ExternalId` condition (D5 confused-deputy protection).
2. **S3 log bucket** seeded with CloudTrail and IAM telemetry fixtures.
3. **SQS notification queue** receiving `s3:ObjectCreated:*` events, backed by a dead-letter
   queue with `maxReceiveCount = 5` (D12).
4. **Local `signal-ingest` runner** compiling with FrostDB and polling live observations
   to prove end-to-end ingestion and queue acknowledgement.

## Operator commands

### Preflight check and dry run

To validate configuration and Terraform syntax without provisioning cloud resources:

```bash
scripts/slaws-live-lab.sh --dry-run --region us-east-1
```

### Running the live lab

To execute the live validation with an authenticated AWS profile:

```bash
scripts/slaws-live-lab.sh --profile my-profile --region us-east-1
```

Or pass `AWS_PROFILE` via environment:

```bash
AWS_PROFILE=my-profile scripts/slaws-live-lab.sh --region us-east-1
```

### Keeping lab resources for debugging

By default, the script tears down all AWS resources upon exit. To inspect the
running resources or query the store:

```bash
scripts/slaws-live-lab.sh --profile my-profile --region us-east-1 --keep
```

### Manual teardown

To destroy an existing lab deployment:

```bash
scripts/slaws-live-lab.sh --profile my-profile --region us-east-1 --destroy
```

## Command options

| Flag | Description | Default |
| :--- | :--- | :--- |
| `--profile` | AWS CLI profile to authenticate | `$AWS_PROFILE` |
| `--region` | AWS region for lab deployment | `$AWS_REGION` or `us-east-1` |
| `--dry-run` | Validate configuration without applying | `false` |
| `--apply` | Apply Terraform resources without starting the ingest server | `false` |
| `--destroy` | Destroy lab infrastructure and exit | `false` |
| `--keep` | Preserve lab resources on exit | `false` |
| `-h`, `--help` | Show usage summary | |

## What the run proves

1. **Credential and Trust Boundary (D5):** The collector assumes the cross-account role
   only when presented with the correct `sts:ExternalId`. A missing or mismatched external
   ID is refused before any telemetry is fetched.
2. **S3 Event Ingestion:** S3 `s3:ObjectCreated:*` notifications queued in SQS are parsed
   and fetched by `signal-ingest`.
3. **Observation Projection (§2.3):** Raw CloudTrail and IAM records are projected into
   `model.Observation` records with `labels.provider=aws` and `raw_evidence_ref` prefixed
   with `s3://<bucket>/`.
4. **Delete-After-Append (D4, §6.3):** The SQS notification message is deleted only
   after `Store.Append` durably records every observation. Once processed, the queue
   depth returns to zero visible and zero in-flight messages.
