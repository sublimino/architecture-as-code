# SLAWS — read-only cross-account trust for the Kusari pilot (template)

Decision D5: Signal Loom never writes into the customer account. The assumed role carries exactly three permissions. Replace the placeholders before sending.

## 1. Role in the customer account

Trust policy (who may assume):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::<SIGNAL_LOOM_ACCOUNT_ID>:role/signal-loom-collector" },
    "Action": "sts:AssumeRole",
    "Condition": { "StringEquals": { "sts:ExternalId": "<EXTERNAL_ID>" } }
  }]
}
```

Permission policy (what it may do):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:GetObject"], "Resource": "arn:aws:s3:::<LOG_BUCKET>/*" },
    { "Effect": "Allow", "Action": ["sqs:ReceiveMessage", "sqs:DeleteMessage"], "Resource": "arn:aws:sqs:<REGION>:<CUSTOMER_ACCOUNT_ID>:<LOG_QUEUE>" }
  ]
}
```

No `iam:*`, no `s3:Put*`, no `s3:Delete*`, no `sqs:Send*`. The collector's `STSAssumer` refuses to assume without a non-empty external ID (ISC-59).

## 2. Delivery plumbing (customer side)

- CloudTrail (management events, all regions) and IAM audit deliver to `<LOG_BUCKET>`.
- VPC Flow Logs (v2 format) deliver to the same bucket under `vpcflow/`.
- An S3 event notification for `s3:ObjectCreated:*` posts to `<LOG_QUEUE>`.
- Objects stay in the bucket under the customer's own retention. Signal Loom stores a projection (proposal §2.3) and a reference `s3://<LOG_BUCKET>/<key>#<record-index>`; it never stores the raw record.

## 3. Signal Loom side

One `awslogs` collector instance per customer account, configured with:

| Variable | Value |
| :--- | :--- |
| `COLLECTOR_AWSLOGS_MODE` | `live` (pilot) or `fixture` (local EAP) |
| `AWSLOGS_TENANT_ID` | `kusari` |
| `AWSLOGS_ROLE_ARN` | `arn:aws:iam::<CUSTOMER_ACCOUNT_ID>:role/<ROLE_NAME>` |
| `AWSLOGS_EXTERNAL_ID` | `<EXTERNAL_ID>` from a Secret, never in argv or ConfigMap |
| `AWSLOGS_QUEUE_URL` | `https://sqs.<REGION>.amazonaws.com/<CUSTOMER_ACCOUNT_ID>/<LOG_QUEUE>` |
| `AWSLOGS_REGION` | `<REGION>` |

Message deletion happens only after `Store.Append` returns, so a crash between receipt and persistence re-delivers the message rather than losing it (proposal §6.3).

## 4. What the pilot will and will not do

- Will: read objects, project them, store findings and decisions, post alert webhooks, show the cloud layer on Weave.
- Will not: create, modify or delete anything in the customer account. Revocation, if ever wanted, is a separate proposal with a write-scoped role and a dry-run default.
