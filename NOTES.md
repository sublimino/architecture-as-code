# F4-edge — build notes

Branch `feat/gcp-tf-edge`. Chunk: the public-facing security boundary — a global external HTTPS
load balancer with a default-deny Cloud Armor policy, replacing the ngrok tunnel.

## What was built

| Path | What |
|---|---|
| `terraform/modules/edge/main.tf` | LB frontend, backend service, health check, URL maps, DNS |
| `terraform/modules/edge/armor.tf` | Cloud Armor policy + priority bands + allowlist chunking |
| `terraform/modules/edge/variables.tf` | 15 inputs, validated |
| `terraform/modules/edge/outputs.tf` | the four contract outputs |
| `terraform/modules/edge/README.md` | allowlist-is-not-authentication, header-strip config |
| `terraform/modules/edge/tests/*.tftest.hcl` | 3 files, **28 runs**, all `command = plan` |
| `scripts/gcp-tf/edge-probe-{negative,positive,bypass}.sh` | manual post-deploy probes |
| `test/terraform-edge-security.bats` | **22 tests**, incl. 4 mutation checks |
| `test/fixtures/terraform/edge/*.tf.fixture` | 4 mutation fixtures |

**Why `armor.tf` is a separate file.** The mutation fixtures are drop-in replacements for it. If
the policy had stayed inside `main.tf`, the mutation harness would have had to excise a resource
block by line number, which breaks the first time anyone edits above it. Giving the resource a
file makes the swap exact. The chunking locals moved with it so a fixture can mutate the chunker
itself — silent truncation is the failure this module most needs to be provably able to fail on.

## Verification (all offline, no credentials, no apply)

```
terraform fmt -recursive -check terraform/modules/edge   clean
terraform -chdir=terraform/modules/edge validate         Success
tflint --chdir terraform/modules/edge                    rc=0
terraform -chdir=terraform/modules/edge test             28 passed, 0 failed
shellcheck scripts/gcp-tf/edge-probe-*.sh                clean
bats test/terraform-edge-security.bats                   22 passed  (7.6s)
```

No `terraform apply`, no `terraform destroy`, no `init` against a real backend, no mutating
`gcloud`, no real network request. Working gcloud credentials exist on this machine and were not
used.

## ISCs claimed

**ISC-122 … ISC-145, ISC-147 … ISC-154** — all satisfied.
**ISC-328, ISC-332, ISC-334, ISC-346, ISC-348** — all satisfied.

## ISCs NOT met

**ISC-146** — "a test asserts each environment's hostname is unique across the map."
Not implementable here and not mine to implement. Per CONTRACT §4 this module receives a single
*resolved* hostname; the map never enters it, so no test in this module can observe uniqueness.
CONTRACT §3 already assigns the uniqueness validation to F2's `modules/env-contract`
(mandatory validation #4), and ISC-343 covers proving it with `expect_failures`. **The
orchestrator should reassign ISC-146 to the F2/environments chunk.** What this module *can*
enforce, and does, is ISC-145: the hostname embeds the environment key — see the objection below.

## Contract objections and integration risks

**1. Three additive inputs beyond CONTRACT §4.** `rate_limit_ban_duration_sec` (600),
`health_check_path` (`/healthz`), `backend_port_name` (`http`). Each has a safe default, so a
caller passing only the contract inputs gets correct behaviour and the frozen signature still
works. Recorded rather than changed unilaterally. A finite ban duration is required by ISC-137
but has no contract input, so one had to exist somewhere.

**2. Cross-chunk dependency on F3 that the contract does not state.** The backend service targets
the instance group by *named port* (`backend_port_name`, default `"http"`). **`modules/compute`
must declare a `named_port` with that name bound to `app_port` on the instance group it outputs.**
If it does not, the load balancer plans and applies cleanly and then serves 502s — the failure
appears at runtime, not at plan, and looks like an application fault. This is the most likely way
the merged tree breaks. Worth a joint assertion once F3 and F4 are on one branch.

**3. `hostname` must embed `environment_key` — stricter than the contract's type.**
ISC-145 requires it, so `google_compute_managed_ssl_certificate.edge` carries a `lifecycle`
precondition enforcing it. CONTRACT §3 only requires hostnames to be unique across the map. If
`environments` supplies, say, `hostname = "signalloom.example.invalid"` for `demo-1`, the plan
**fails** with an explicit message. That is deliberate — a certificate issued for the wrong
environment's name is not a thing to warn about — but it is a constraint the environment map
authors have not been told about. Either the contract's type should document it or the demo map
must use key-embedded hostnames.

**4. `test/terraform-edge-security.bats` contains the literal `/home/[a-z]`** on line ~315. It is
the *detector* for the no-absolute-path rule, not a hardcoded path. A repo-wide scan by another
chunk's guard will flag it. Left as a readable literal rather than obfuscated.

**5. Added `terraform/modules/edge/.gitignore` containing `.terraform/`.** The repo root
`.gitignore` has no terraform entries and is shared with the other chunks, so scoping it to my own
directory avoided a merge conflict. The orchestrator may prefer to hoist it to the root
`.gitignore` at merge time.

## How the 10-CIDR-per-rule limit is handled

Chunked, never truncated. `chunklist(var.allowed_ipv4, 10)` and `chunklist(var.allowed_ipv6, 10)`
are concatenated into `local.raw_chunks`, then `local.allow_chunks` assigns priorities from a
**single shared index across both address families** — indexing each family separately would give
an IPv4 chunk and an IPv6 chunk the same priority, which the API rejects at apply time and which
no plan would reveal. Each chunk produces two rules: a `rate_based_ban` at `800+n` and a plain
`allow` at `1000+n`. Both allowlist variables are capped at 500 entries (50 chunks) by a
`validation` block, so a generated priority can never cross into the next band.

`tests/allowlist_chunking.tftest.hcl` supplies **25 CIDRs** and asserts three separate things:
the allow-rule count is 3 (`ceil(25/10)`), the union of `src_ip_ranges` across the evaluated rules
is **25 distinct entries**, and that set is **equal to the input set**. The count is the only
assertion that catches silent truncation — "some allow rules were planned" is true whether 25
CIDRs survived or 10 did. Set equality catches the other direction: 25 of the *wrong* CIDRs. A
second run crosses the boundary in both families at once (12 IPv4 + 11 IPv6 → 4 chunks) and
asserts no priority collision.

## What the orchestrator must know before merging

1. **ISC-146 needs reassigning to F2/environments** (see above). Do not mark it done from here.
2. **Verify F3's `modules/compute` declares the named port** — objection 2. This is the one defect
   that survives every test in both chunks and only appears in a running system.
3. **The demo environment map must use key-embedded hostnames** (`demo-1.example.invalid`, not
   `signalloom.example.invalid`) or the plan fails — objection 3.
4. **The probe scripts make real network requests and must never run in CI.** They are manual,
   post-approval tools. Only `--dry-run` is safe unattended, and the bats suite exercises only
   that path (with a curl stub on PATH that fails loudly if invoked, proving the dry-run is
   genuinely offline rather than merely working on a connected machine).
5. **The mutation checks need `.terraform/` present** in `terraform/modules/edge` — i.e.
   `terraform init -backend=false` must have run there. The bats file attempts it in `setup_file`
   and, if the provider schema is still absent, the mutation tests **fail loudly rather than
   skipping**. A skipped mutation check is a guard that has not been shown to work, which is the
   state this whole chunk was told to design against. If CI is fully offline, add the init to the
   Make target (I did not touch the Makefile).
6. **Nothing was applied and no GCP resource exists.** The approval gate is intact.

## Design decisions worth a second opinion

- **The plain-allow band at priority 1000+n is unreachable** while the rate-limited rules at 800+n
  exist, and that is deliberate: the source ranges are identical, so deleting a rate-limit rule
  degrades to "allowed but unthrottled" rather than "denied". It can never widen exposure beyond
  the allowlist. If you would rather a deleted rate-limit rule caused an outage than a silent loss
  of throttling, drop the 1000 band.
- **Port 80 is structurally incapable of serving content**: its URL map has a `default_url_redirect`
  and *no* `default_service`, `path_matcher`, or `host_rule`. It cannot reach a backend even if a
  forwarding rule were later pointed at it by mistake. The tftest asserts the absence of those
  blocks, not just the presence of the redirect.
- **`X-Forwarded-For` is deliberately not stripped** — the load balancer owns it and Cloud Armor
  source matching and logging depend on it. A tftest asserts it stays in place, so a future
  well-meaning "strip all forwarded headers" edit fails the suite.
- **An empty allowlist is legal and is the safe state**: no allow rules, default deny only. A
  tftest asserts an empty list never degrades to "allow everything".
