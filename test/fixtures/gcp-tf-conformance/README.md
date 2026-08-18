# gcp-tf-conformance fixtures

Canned `gcloud --format=json` responses that drive `scripts/gcp-tf/conformance.sh`
and `scripts/gcp-tf/teardown-verify.sh` with no cloud account, no credentials and
no network.

## How the stub finds a fixture

`stub-gcloud.sh` is copied onto `PATH` as `gcloud`. It slugs the invocation by
joining every non-flag token up to and including the first `describe`, `list`,
`version` or `get-iam-policy`, then serves `<slug>.json`:

| invocation | slug |
|---|---|
| `gcloud compute instances list --project p` | `compute-instances-list` |
| `gcloud compute security-policies describe sl-demo-1-armor` | `compute-security-policies-describe` |
| `gcloud iap web get-iam-policy --service=x` | `iap-web-get-iam-policy` |
| `gcloud storage buckets describe gs://b` | `storage-buckets-describe` |

Two directories are searched, overlay first:

```
STUB_FIXTURE_OVERLAY=.../external-ip     # only the files this scenario changes
STUB_FIXTURE_BASE=.../compliant          # everything else
```

A scenario directory therefore holds **only the difference**, which is what
makes each negative test a single readable file. A fixture whose whole content
is `__STUB_ERROR__` makes that one call fail, which is how "the state bucket is
gone" and "this API returned PERMISSION_DENIED" are expressed.

A slug with no fixture in either directory makes the stub exit non-zero. That is
deliberate: the scripts must report UNKNOWN, never FAIL, when they could not
look, and a missing fixture is the cheapest way to prove it.

## The decoys in `compliant/`

`compliant/` is not a minimal happy path. It carries three resources that must
NOT be flagged, each guarding a specific way the scoping logic could be wrong:

| decoy | what it would catch |
|---|---|
| `sl-demo-10-vm`, external IP, default compute SA, shielded off | prefix matching without the trailing hyphen — `startswith("sl-demo-1")` matches `sl-demo-10-vm`, and a whole other environment gets graded as this one |
| `sl-demo-1-deny-all-ingress` with `sourceRanges: ["0.0.0.0/0"]` | flagging `0.0.0.0/0` on a **deny** rule, which is the normal and correct shape of a default-deny |
| `sl-demo-1-legacy-open`, `allowed` from `0.0.0.0/0`, `disabled: true` | flagging a rule that is not in force |

So "the compliant estate reports all PASS" is not a formality. Three distinct
over-broad implementations turn it red.
