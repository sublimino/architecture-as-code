# H2 — live conformance and teardown verification

Everything the repo had before this chunk asserts on Terraform **configuration**.
`terraform test` reads evaluated plan attributes; bats reads the tree. Neither
asks the running cloud whether the posture actually landed, and config and
reality diverge in exactly the ways that hurt: a shadowed firewall rule, an IAP
binding that applied to a different backend, an org policy that overrode
public-access-prevention after apply, a console change made at 19:00.

Two scripts close that gap, and one offline suite proves they work.

| path | what it does |
|---|---|
| `scripts/gcp-tf/conformance.sh` | read-only assertions against a LIVE environment |
| `scripts/gcp-tf/teardown-verify.sh` | run AFTER a destroy: the environment is gone AND the foundations survived |
| `test/terraform-conformance-harness.bats` | 34 tests, offline, `gcloud` is a stub on PATH |
| `test/fixtures/gcp-tf-conformance/` | the canned estates, plus `stub-gcloud.sh` and a README explaining the fixture protocol |

## Invocations

After `make gcp-tf-apply ENV=demo-1`:

```bash
scripts/gcp-tf/preflight.sh --project <PROJECT> --bucket <STATE_BUCKET>
scripts/gcp-tf/conformance.sh \
  --project <PROJECT> --env demo-1 --bucket <STATE_BUCKET> --strict
```

`--strict` exits 3 when nothing failed but something could not be checked. Use it
in CI; drop it when you are inspecting by hand and expect gaps.

After `make gcp-tf-destroy ENV=demo-1`:

```bash
scripts/gcp-tf/teardown-verify.sh \
  --project <PROJECT> --env demo-1 --bucket <STATE_BUCKET> \
  --other-env demo-2            # repeat for every environment that must survive
```

Then spin back up and re-run `conformance.sh`. Exit codes on both scripts: `0` no
FAIL, `1` at least one FAIL, `2` usage, `3` `--strict` with unknowns.

Offline suite: `bats test/terraform-conformance-harness.bats`, or via the repo's
own discovery, `make gcp-tf-validate` — the glob `test/terraform-*.bats` picks
the suite up with no Makefile change.

## Check → SECURITY.md threat row

Every verdict line carries its threat row inline, so a failure says which threat
is live rather than which assertion tripped.

| check | SECURITY.md | what a FAIL means |
|---|---|---|
| no external IP on any instance | §3 Direct VM exposure | the VM routes around the load balancer and Cloud Armor together |
| OS Login on, project SSH keys blocked | §3 | SSH authorisation is not going through IAM |
| Shielded VM: secure boot + vTPM + integrity | §3 | a tampered boot chain would not be detected |
| per-environment runtime service account | §2 Over-broad CI identity | the default compute SA is shared and broad |
| no `0.0.0.0/0` ingress in the environment's network | §3 | the whole internet reaches the VPC regardless of Cloud Armor |
| SSH only from `35.235.240.0/20` | §3 | SSH is reachable outside IAP TCP forwarding |
| Cloud Armor attached, default rule denies, not in preview | §5 The allowlist mistaken for authentication | the policy is allow-by-default, so the allowlist is decoration |
| IAP enabled on the backend service | §5a The access-mode decision | requests reach the backend unauthenticated |
| IAP names a principal, and not `allUsers`/`allAuthenticatedUsers` | §5a | **the demo is public** |
| state bucket versioning + UBLA + PAP enforced | §1 State bucket exposure or deletion | state holds resource ids and IAM member lists |
| no user-managed service account key | §2 | a downloadable credential that outlives its owner |

Teardown maps to §1 (the state bucket must survive), §6 Cross-environment
collision (other environments must be untouched), and §10 Cost as a security
property (orphans keep charging).

`allAuthenticatedUsers` gets the loudest failure in the file, per SECURITY.md
§5a: it reads as a restriction and means any Google account on earth.

## What can only be UNKNOWN without a live estate

Everything. Both scripts are pure observers — with no deployed environment there
is nothing to observe, and the offline suite proves the scripts *behave*, not
that any estate is conformant. Specifically:

- **Every conformance check is UNKNOWN until `demo-1` is applied.** No instance
  named `sl-demo-1-*` means UNKNOWN, never PASS. An empty estate must not read
  as a clean one; that is the failure mode where running against the wrong
  `--env` reports a perfect score.
- **State bucket checks are UNKNOWN without `--bucket`.** The name is never
  guessed.
- **`teardown-verify.sh`'s collateral-damage check is UNKNOWN without
  `--other-env`.** "Nothing else was harmed" with nothing named is an
  assumption, not a finding.
- **Anything the caller's identity cannot read is UNKNOWN.** Run `preflight.sh`
  first; a wall of UNKNOWNs is almost always the ADC/CLI identity split it was
  written to catch.

## Design decisions worth knowing before merging

**No server-side `--filter` on any absence check.** A mistyped filter returns an
empty list, an empty list is exactly what "clean" and "destroyed" look like, and
the report goes green on a question it never asked. Lists are fetched whole and
filtered in-script, where the filter is visible and the suite can reach it. A
bats test asserts no `--filter` appears in the recorded call log.

**The trailing hyphen in prefix matching is load-bearing.** `sl-demo-1` is a
prefix of `sl-demo-10`. The compliant fixture deliberately carries an
`sl-demo-10-vm` with an external IP, no OS Login and the default compute SA, so
dropping the hyphen turns the *positive* test red — proven by a mutation check.

**Read-only by mechanism, not by promise.** Both scripts carry the same
`gcloud_ro()` allowlist gate `preflight.sh` uses. `get-iam-policy` is added to
the allowlist with a comment; its mutating twin `set-iam-policy` is not, and a
test asserts both scripts refuse it. Each script ends with a `BASH_SOURCE` guard
so the suite can source it and drive the gate directly — a gate nobody can call
in isolation is a gate nobody tests.

**One deliberate exception to the UNKNOWN rule**, in
`check_state_bucket_survives`. If the bucket describe fails *while every other
read in the run also failed*, that is a credential problem and the verdict is
UNKNOWN. If it fails *while other reads succeeded*, the identity works and this
one bucket did not answer — FAIL, loudly. The discrimination uses a marker file
rather than a shell variable, because every cloud read happens inside a command
substitution and a counter incremented in a subshell is discarded; a variable
there would have read zero forever and the FAIL branch could never fire.

**`jq` is a hard dependency.** Both scripts exit 2 if it is absent rather than
reporting a wall of UNKNOWNs that hides the real cause.

## Response shapes: verified vs. assumed

Fixtures were written from the documented API schemas. `sl-port-over-sandbox`
currently holds **no buckets** (`gcloud storage buckets list` returns `[]`), so
nothing could be recorded from a live estate. Two consequences the orchestrator
should carry:

1. **`storage buckets describe` field names are accepted in both shapes.**
   `gcloud storage` renders snake_case top-level fields (`versioning_enabled`,
   `uniform_bucket_level_access`, `public_access_prevention`); the raw JSON API
   renders an `iamConfiguration` object. The check reads either. If both are
   wrong the verdict is UNKNOWN or FAIL, never a false PASS — but **re-check
   this one against the real bucket on the first live run**.
2. **`iap.enabled` on the backend service and the `roles/iap.httpsResourceAccessor`
   binding shape are from documentation, not observation.** Same failure
   direction: a shape mismatch degrades to UNKNOWN/FAIL, not to a false PASS.

The first live run is therefore also a fixture-recording opportunity. If a shape
differs, update the fixture and the suite re-proves the check in seconds.

## Limits

- Both scripts observe the control plane. They do not send a request at the load
  balancer — that is what `scripts/gcp-tf/edge-probe-{positive,negative,bypass}.sh`
  are for, and the two are complementary: control-plane state can be right while
  the data path is wrong, and the reverse.
- Instance-level checks cover instances named `sl-<env>-*`. An instance created
  by hand under another name inside the environment's VPC is not graded (the
  firewall checks are network-scoped and would still see rules affecting it).
- Orphan detection is name-scoped to the environment. A hand-created disk or
  address under a different name survives a clean report; the budget alert in
  `modules/observability` is the compensating control.
