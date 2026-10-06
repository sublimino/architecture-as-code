# Runbook — multi-account AWSLogs configuration and dead-letter queue redrive

> SLAWS v2 §3, D11, D12. Owner: Signal Loom platform.
> Code: `d2-signalloom/apps/signal-ingest/collectors/awslogs/accounts.go`, `collectors/awslogs_redrive.go`.

## What this is for

Signal Loom ingests AWS CloudTrail, IAM, and VPC Flow telemetry across multiple customer accounts.
Each customer account runs as an independent `awslogs` collector instance with its own:

- AWS credentials (cross-account IAM role assumption)
- SQS notification queue and S3 telemetry source
- Tenant binding (preventing telemetry cross-contamination)
- WAL directory (independent disk ring buffer)

This runbook covers how to configure multiple accounts and how to redrive dead-lettered notifications from an SQS Dead Letter Queue (DLQ).

## Multi-account configuration

The collector reads customer accounts from the environment variable `COLLECTOR_AWSLOGS_ACCOUNTS`.
In Kubernetes, this variable is populated from a Secret through `secretKeyRef`.

### JSON configuration format

`COLLECTOR_AWSLOGS_ACCOUNTS` contains a JSON list of account entries:

```json
[
  {
    "account_id": "123456789012",
    "role_arn": "arn:aws:iam::123456789012:role/kusari-telemetry-read",
    "external_id": "kusari-ext-49f2",
    "queue_url": "https://sqs.us-east-1.amazonaws.com/123456789012/kusari-telemetry-queue",
    "tenant_id": "kusari",
    "region": "us-east-1"
  },
  {
    "account_id": "210987654321",
    "role_arn": "arn:aws:iam::210987654321:role/acme-telemetry-read",
    "external_id": "acme-ext-881a",
    "queue_url": "https://sqs.us-east-1.amazonaws.com/210987654321/acme-telemetry-queue",
    "tenant_id": "acme"
  }
]
```

### Fields

| Field | Required | Description |
| :--- | :--- | :--- |
| `account_id` | yes | AWS account ID of the target customer account. |
| `role_arn` | yes | ARN of the cross-account role to assume. |
| `external_id` | yes | STS external ID required to assume the role. |
| `queue_url` | yes | SQS queue URL receiving S3 object notifications. |
| `tenant_id` | yes | Tenant ID bound to all observations from this account. |
| `region` | no | AWS region for SQS and S3. Defaults to `AWSLOGS_REGION` or `us-east-1`. |

### Fail-closed boot rules

Validation runs at startup before the HTTP listener opens. The service refuses startup and exits with code 1 if:

1. Any required field is missing or empty, naming the offending index (for example `COLLECTOR_AWSLOGS_ACCOUNTS[1]: queue_url is required`).
2. Two entries share an `account_id` or a `queue_url`, naming both indexes.
3. The JSON string is invalid or malformed.

If `COLLECTOR_AWSLOGS_ACCOUNTS` is empty or unset, `signal-ingest` falls back to the single-account `AWSLOGS_*` environment variables.

### Kubernetes Secret deployment

Example Secret manifest (`fe-signalloom/local/signal-ingest-awslogs-accounts-example.yaml`):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: signal-ingest-awslogs-accounts
  namespace: fe-signalloom
type: Opaque
stringData:
  accounts.json: |
    [
      {
        "account_id": "123456789012",
        "role_arn": "arn:aws:iam::123456789012:role/kusari-telemetry-read",
        "external_id": "kusari-ext-49f2",
        "queue_url": "https://sqs.us-east-1.amazonaws.com/123456789012/kusari-telemetry-queue",
        "tenant_id": "kusari",
        "region": "us-east-1"
      }
    ]
```

The Deployment mounts this via `secretKeyRef` with `optional: true`:

```yaml
- name: COLLECTOR_AWSLOGS_ACCOUNTS
  valueFrom:
    secretKeyRef:
      name: signal-ingest-awslogs-accounts
      key: accounts.json
      optional: true
```

---

## Dead-letter queue redrive

When SQS messages fail repeatedly or exceed the maximum receive count on the primary queue, the SQS redrive policy moves them to the Dead Letter Queue (DLQ).
The `signal-ingest awslogs redrive` subcommand replays those messages through the same projection and deduplication pipeline as live ingest.

### The redrive command

```bash
signal-ingest awslogs redrive \
  --queue https://sqs.us-east-1.amazonaws.com/123456789012/kusari-telemetry-dlq \
  --account 123456789012 \
  --max 500
```

### Flags

| Flag | Required | Default | Description |
| :--- | :--- | :--- | :--- |
| `--queue` | yes | | SQS Dead Letter Queue URL to read messages from. |
| `--account` | no | | AWS account ID matching an entry in `COLLECTOR_AWSLOGS_ACCOUNTS`. |
| `--max` | no | `1000` | Maximum number of records to process. Must be greater than 0. |
| `--dry-run` | no | `false` | Receive and process records without deleting them from the DLQ. |

### Exit codes

- `0`: Success.
- `1`: Runtime error (store unavailable, authentication error, poll failure).
- `2`: Bad command arguments (missing `--queue` or `--max <= 0`).

### Output format

The command writes a single JSON object to standard output:

```json
{
  "redriven": 42,
  "duplicates": 12,
  "discarded": 0,
  "unparseable": 0
}
```

- `redriven`: Number of records acknowledged and removed from the DLQ.
- `duplicates`: Number of observations suppressed by content-addressed ID deduplication (already present in the store).
- `discarded`: Messages deleted because they contained no actionable S3 object references (for example `s3:TestEvent`).
- `unparseable`: Poisoned messages that could not be parsed as valid S3 notifications. These messages are left in flight in the DLQ and never deleted.
