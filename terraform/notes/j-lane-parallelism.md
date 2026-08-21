# j — Running demo-1, demo-2, ci-1 and ci-2 at the same time

> **Verdict: the binding constraint is a CEILING, not a race. Four lanes as
> originally sized could never coexist — 48 vCPU against a global cap of 32 —
> and the second ceiling, disk, would have stopped the rebuild that fixed the
> first. Underneath that sits one genuinely silent correctness bug in the
> access path. The Terraform axis everybody expected to be the problem is
> safe, and that was established by running it rather than by reading it.**

## 0. The headline: the estate cannot hold four lanes, and never could

Two independent quota ceilings, found in that order and both binding.

**CPU.** A cold `demo-2` apply failed on 2026-08-20:

    Error: Error waiting for instance to create: Quota 'CPUS_ALL_REGIONS'
    exceeded. Limit: 32.0 globally.

`CPUS_ALL_REGIONS` was 32.0/32.0, exhausted by demo-1 (n2-standard-16 = 16) +
ci-1 (8) + ci-2 (8). demo-2 wanted 16 more. **Four lanes as sized needed 48 vCPU
against a global cap of 32.**

The regional quota is the misleading part and worth stating explicitly: `N2_CPUS`
in us-east4 is **200** with usage 32. The region has enormous headroom. It is the
*global* all-regions cap that binds, which is why this presents as a capacity
problem in a region that plainly has capacity.

The failure was also partial rather than clean: demo-2's VPC, subnet, router,
NAT, DNS zone and all nine firewall rules created successfully, and only
`google_compute_instance.this` failed — leaving a half-built lane that reads as a
broken apply rather than as a ceiling. `scripts/gcp-tf/preflight.sh` now refuses
an apply that cannot fit, reporting CPU and SSD separately; that is the
enforcement point any ordering guarantee should hang on.

**Disk.** Found before it could cost a second failed rebuild. `SSD_TOTAL_GB` in
us-east4 was 400.0/500.0 with three `pd-balanced` disks at 100/100/200. All boot
disks are `pd-balanced`, which bills against `SSD_TOTAL_GB` and **not**
`DISKS_TOTAL_GB` — confirmed by `DISKS_TOTAL_GB` sitting at 32/4096 while SSD sat
at 400/500. Rebuilding four lanes at the CPU-safe size would have put the fourth
lane at 600GB against a 500GB limit.

Resolved by dropping **both** demo lanes to `boot_disk_gb = 100`: 4 × 100 = 400GB
with 100GB spare, rather than one lane landing on exactly 500/500 with none.
`COMPUTE-RULE-03-BOOT-DISK` validates a floor of 100 and both CI lanes had been
running at 100GB successfully, so 100 is empirically sufficient rather than
merely legal.

**The estate is now at the validated floor on disk, and this is worth a line
because the failure mode of a full disk is expensive to diagnose: image-pull
errors scattered across unrelated pods.** Nothing in the bring-up fails loudly on
low disk. Raising `SSD_TOTAL_GB` to 1000 and putting the demo lanes back to 200GB
is the real fix.

**Suspend frees CPU quota and does not free disk quota** (measured: 32.0 → 24.0
on suspending one 8-vCPU lane). A suspended instance keeps its disk. So the
hot-cold lane strategy buys CPU headroom and buys nothing at all against the SSD
ceiling — which is why the preflight reports the two separately.

## 0a. Zero headroom is now a design property

Four lanes at `n2-standard-8` is **exactly** 32 vCPU against a cap of 32. At the
cap, any operation that briefly runs N+1 instances fails, and it fails with the
same `CPUS_ALL_REGIONS exceeded` message — which reads as "we need more quota"
rather than "we asked for one more VM than we can hold".

**Today no lane operation transiently doubles an instance. That verdict is SAFE,
and it rests on an ABSENCE rather than a decision, which is why it now has a
test.**

- `machine_type` is not ForceNew in the Google provider and
  `allow_stopping_for_update = true`, so a **resize** stops and starts the same
  instance. No second instance exists at any point.
- `boot_disk.initialize_params` **is** ForceNew, so changing `boot_disk_gb`
  replaces the instance — but Terraform's default is destroy-then-create. The
  estate goes N-1, then N. It never goes N+1.
- `grep -rn create_before_destroy terraform/` returns **nothing**.

That last one is the fragile part. Adding `create_before_destroy` is an ordinary,
well-intentioned change — it is the standard way to cut replacement downtime, and
on any estate with headroom it is strictly better. Here it would make every
disk-triggered replacement fail at the quota. `test/terraform-lane-quota-headroom.bats`
now asserts its absence, with the reason and an instruction to delete the test
the day the quota is raised. Its negative assertion is exercised against a
scratch tree that really does contain the string, because "this string does not
appear" is the shape that passes hardest when the thing it guards has been
renamed or deleted.

**Teardown/rebuild ordering is load-bearing at the cap.** Rebuilding four lanes
in parallel from zero is fine (0 → 32). Rebuilding while any old lane still
exists is not. The sequence actually used — destroy demo-1, recreate at 8,
create demo-2 — went 32 → 16 → 24 → 32 and fits under both ceilings at every
step.

---

## The original question, and the answer to it

The brief asked whether two or more concurrent `make gcp-tf-*` invocations with
different `ENV=` values can corrupt each other, silently operate on the wrong
environment, or deadlock — including the hard case of a cold
`gcp-tf-up ENV=demo-2` applying while the other three lanes run tests.

**The per-lane mechanisms already in the Makefile are correct and they work**, and
that was established by running them rather than by reading them. Every axis of
Terraform's own bookkeeping is genuinely per-lane: the data dir, the state prefix
and therefore the state lock, the plan file, the handoff.

What is *not* per-lane is everything outside it, and it divides in two. **The
ceilings** — global CPU quota and regional SSD quota — are shared by construction
and cannot be fixed from this repo; they are §0. **The operator's own machine**
is the part that was silently wrong, because every lane wants the same loopback
port and the driver could not tell whose tunnel answered; that is §3, and it is
fixed. The reaper's notion of an idle lane (§4) is a third category: correct in
isolation, dangerous only once someone schedules it.

Every verdict below is CLASHES, SAFE or UNKNOWN, with what was actually done to
establish it. Where the answer is SAFE, the experiment that could have shown
otherwise is named, because "I read the Makefile and it looked per-lane" is not
the same claim.

---

## 1. The shared `.terraform.lock.hcl` — SAFE

**Candidate:** `terraform init -reconfigure` runs with `TF_DATA_DIR` pointed at a
per-lane directory, but `.terraform.lock.hcl` is not written to `TF_DATA_DIR`. It
is written to the configuration root, and all four lanes share one root
(`terraform/environments/`). Four concurrent inits therefore write one file. This
was the most likely real clash and it is why it was tested first.

**Verdict: SAFE.** Concurrent init does not corrupt it and does not fail.

**Evidence.** Two experiments, both from a genuinely cold tree (`.terraform-ci-1`,
`.terraform-ci-2`, `.terraform-demo-1` removed, so every lane did a real provider
download into its own data dir — ~240MB each, confirmed by `du`).

*Experiment 1* — three concurrent `make gcp-tf-plan` (`ci-1`, `ci-2`, `demo-1`)
against the real GCS backend, with a 50ms watcher sampling the lock file
throughout:

    ci-1     rc=0  elapsed=14s
    ci-2     rc=0  elapsed=14s
    demo-1   rc=0  elapsed=15s
    lock transitions: 1  (size=2266, unchanged)
    lock file vs before: IDENTICAL

That shows no corruption, but it does not show much: the lock was already
complete for `linux_amd64`, so init only ever *read* it. The interesting case is
a lock that must be **written**.

*Experiment 2* — first attempt was wrong and is recorded because the wrong
version is instructive. Stripping the `h1:`/`zh:` lines left `hashes = [ ]`
blocks, and all three lanes then failed identically with `Invalid provider hash
set`. That is a deterministic parse error caused by the mutation, not a
concurrency failure — three identical failures with one cause. Attributing it to
concurrency would have shipped a fabricated finding.

*Experiment 2b* — the correct form: delete the lock file outright and remove all
per-lane data dirs, so every concurrent init must legitimately regenerate it.

    ci-1     rc=0    0 error lines
    ci-2     rc=0    0 error lines
    demo-1   rc=0    0 error lines
    lock transitions:  ABSENT -> size=2266  (one transition, no intermediate state)
    final vs pristine: IDENTICAL

No torn write was ever observable. Terraform writes the lock through a temp file
and renames it, so the worst case is last-writer-wins — and the writers cannot
disagree, because all four lanes share one root and therefore resolve one
provider set. **That last clause is the load-bearing one.** This is safe because
the lanes cannot diverge in their provider requirements, not because concurrent
writes are inherently fine. A future per-lane root, or a lane pinned to a
different provider version, removes the property.

**No fix needed. No guard added** — a guard here would be asserting a property of
Terraform, not of this repo.

## 2. `GCP_TF_VAR_FILE` has a default that never worked — SAFE. Fix attempted and BACKED OUT

**Verdict: SAFE.** It fails closed: `-var-file` naming a missing file is a hard
Terraform error, so a forgotten var file has never produced a plan against wrong
inputs. Nothing silent, nothing cross-lane. This is a usability wart, not a
clash — which matters, because it is the reason the fix below was not worth its
blast radius.

The default is `../../deploy/gcp/environments.tfvars`, a file that has never
existed in this repo — the real one is `deploy/gcp/<project>.tfvars`. So it is
not a convenience that occasionally helps; it is a path that always fails, and it
fails as Terraform's own "Failed to read variables file" quoting a path relative
to a `-chdir` root the operator was not thinking about. `i1-make-handoff.md` §2
already recorded this.

**What was tried.** A `gcp_tf_require_var_file` matching the existing
`gcp_tf_require_state_bucket` / `gcp_tf_require_bootstrap_var_file` shape,
checking existence and listing the tfvars files actually present, wired into
`gcp-tf-plan`, `gcp-tf-destroy` and `gcp-tf-up`, with `GCP_TF_VAR_FILE ?=` made
genuinely empty. It worked exactly as intended against a real checkout:

    ERROR: GCP_TF_VAR_FILE is required for 'gcp-tf-plan' and does not resolve.
           ...
           Inputs files visible in deploy/gcp/ right now:
             GCP_TF_VAR_FILE=../../deploy/gcp/sl-port-over-sandbox.tfvars

**Why it was backed out.** It turned 16 tests in
`test/terraform-make-contract.bats` red, and the reason is structural rather
than fixable in passing. Those tests drive the real targets against a fixture
root produced by `env_fixture()` — a directory under `BATS_TEST_TMPDIR` — with a
stubbed `terraform` that never reads `-var-file`. So no var file has ever existed
on that path, and `<fixture>/../../deploy/gcp/environments.tfvars` resolves
outside the tmpdir to somewhere no fixture can legitimately create. **Any**
existence check on this variable breaks them; the check is not the problem, the
fixture contract is. Making it pass means reworking how `env_fixture` and
`run_make` hand a root to the targets — 16 call sites in a contract suite this
work does not own, to fix something that is not a clash. That is the
rearchitecting this brief rules out.

This is also the reason the bad default survived so long and is worth stating
plainly: **the default is wrong for humans and right for fixtures.** Nothing ever
read it, so nothing ever noticed.

**The recommendation, for whoever picks it up.** The `deploy/gcp/deploy-sa`
pattern — an untracked one-line file read through `$(shell ...)` at parse time
with a fallback, exactly as `TF_DEPLOY_SA` already is. It sidesteps the fixture
problem entirely, because a resolved-with-fallback variable does not assert
existence at recipe time. A *working default* remains wrong for the reason
`TF_STATE_BUCKET` has none: it would have to name the real project's tfvars file,
and `i1-make-handoff.md` §3 already flags the tracked
`sl-port-over-sandbox.example.tfvars` as a defect precisely because its FILENAME
carries the project id.

## 3. The local tunnel port — CLASHES, SILENTLY. FIXED

**This is the one that mattered.** It is not a "port already in use" nuisance. It
is a wrong-lane bug that reports success.

`app_port` is a single value in the shared tfvars — **30754 for all four lanes**
— and `local_tunnel_port()` defaults the LOCAL end of the IAP tunnel to it. Four
lanes, one loopback port. Confirmed in both the tfvars (four occurrences) and the
live handoffs (`demo-1.handoff.json` and `demo-2.handoff.json` both
`app_port=30754`).

What makes it silent is the driver's post-launch wait loop:

    if "$PORT_PROBE" "$local_port"; then bound=1; break; fi

`default_port_probe` is `(exec 3<>/dev/tcp/127.0.0.1/$1)`. It answers *"something
is listening"*. It cannot answer *"MY tunnel is listening"*. So with lane A's
tunnel already bound:

1. the operator runs `connect` for lane B;
2. gcloud is backgrounded and spends several seconds authenticating and
   impersonating before it ever attempts its bind;
3. the loop checks `kill -0` (alive — still starting up) and probes the port;
   **lane A answers**;
4. `bound=1`, and the driver prints `tunnel is UP on localhost:30754`.

The operator now works lane B's ticket against lane A's cluster, with nothing in
the output to say so. And step 2 is reached only *after* `dex_origin apply` has
already repointed **lane B's Dex issuer** at an origin lane A is serving — so
even a run that later failed would have mutated lane B's cluster on the way.

`require_no_conflicting_origin` cannot catch this. It asks lane B's own cluster
whether another *access method* holds its issuer; lane A is a different cluster it
never speaks to. Per-lane state is exactly why it is blind here.

**The fix.** `require_local_port_free`, called at the top of `cmd_connect` and
`cmd_public` — before the origin claim and before any cloud call, so a refused run
costs neither a mutation nor a minute of gcloud. It refuses with the escape hatch
named, because Andy's requirement is four lanes at once, not four lanes one at a
time:

    GCP_TF_DEMO_LOCAL_PORT=30755 make gcp-tf-connect ENV=demo-2

**The preflight probe is a second injection point (`GCP_TF_DEMO_PREFLIGHT_PORT_PROBE`),
and that is the design, not duplication.** It asks the opposite question to
`PORT_PROBE` at the opposite moment: "is the port ALREADY taken" (success ⇒
refuse) versus "is it bound yet" (success ⇒ proceed). One injectable cannot
express both — the suites' `probe-ok` stub answers "bound" unconditionally, which
is *correct* for the post-launch question and would make the guard refuse every
single run. `M6` in the mutation proof is that exact collapse.

**Not done: a per-lane default port.** Deriving the local port from the lane key
would make four lanes work with no flag at all, and the driver's own comment
already says the local end "is whatever this machine has free". It was not done
because it changes behaviour two existing contract tests pin
(`--local-host-port=localhost:8080` for the fixture lane), and that is a
deliberate decision to re-take rather than a side effect to absorb. Listed as an
optimisation below.

### 3a. A per-lane port is NOT sufficient, and the second half is the ownership check

A unique port per lane stops the collision. It does not stop the
**misattribution**, and the distinction is the whole of this section.

Two holes survive a per-lane port. First, a race: gcloud spends several seconds
authenticating before it binds, so another lane can take the port inside that
window, after the pre-flight has already passed. Second, and more simply, two
operators can pick the same `GCP_TF_DEMO_LOCAL_PORT`.

So the binding question is not *"is something listening"* but *"is the thing
listening the tunnel I started for THIS lane"*. `assert_tunnel_is_ours` answers it
by asking who owns the listening socket and requiring that pid to be our tunnel
process or a descendant of it. The tunnel was opened with this lane's
`INSTANCE_NAME`, so provenance of the socket **is** identity of the far end.

The descendant walk is not ceremony: `$!` is the pid of the backgrounded `env`,
and against a real gcloud — a wrapper that runs Python — the socket is held by a
child. Collapsing the walk to a direct comparison rejects every legitimate
tunnel, which is mutation M10.

It fails **closed**. An empty owner list means the socket belongs to another user
or `ss` is unavailable; both are refusals, because the question is whether
ownership can be *proven*, not whether a reason can be found to proceed. That is
mutation M9, and it is the fail-open rewrite most likely to be introduced in good
faith by someone whose machine lacks `ss`.

**On far-side attestation — the estate already has it, on one path, and the port
collision is what disables it on the other.** `cmd_ts_test`'s R3 fetches Dex's
discovery document and requires `.issuer` to equal the origin it asked for. That
works over the tailnet because the origin is
`https://sl-<env>.<tailnet>.ts.net` and embeds the lane key, so a wrong lane
answers with an issuer naming *itself*. It cannot work over IAP because the IAP
origin is `http://localhost:<port>` and every lane defaults to the same port — the
issuer string is identical across all four lanes and attests to nothing. **The
colliding port does not merely cause the hijack; it also disarms the one identity
check the estate already owns.**

Two ways to earn attestation over IAP, one nearly free: make the local port
per-lane, which makes the IAP origin lane-specific and brings the *existing* Dex
issuer check into range; or have nginx return the environment key in a header,
which is path-agnostic. Neither replaces the ownership check. Attestation is
**testimony** from whatever is on the other end of the socket; ownership is
**provenance** of the socket itself. A confused or hostile far side can say
anything; a socket's owning pid cannot, and ownership is the only one of the two
available before a byte is exchanged.

### 3b. The tailnet path — NOT covered by this fix, and better defended already

Stated plainly rather than left for a merge to imply: `assert_tunnel_is_ours` is
wired into `cmd_connect` and `cmd_public` only. It **does not cover the tailnet
path**, and it cannot be reused there — there is no local socket we own, because
the connection goes over the tailnet to a remote node.

The tailnet path is structurally in better shape, and for three reasons that the
IAP path lacks:

1. **The names are per-lane and unique by construction** — `sl-demo-1` versus
   `sl-ci-1`, derived as `sl-${ENV_KEY}`, not a shared number.
2. **Resolution is by exact hostname** against the local tailnet, and
   `ts_resolve_node` distinguishes five causes including "no such node" — rather
   than accepting whatever answers on a port.
3. **Far-side attestation is already performed** — the Dex issuer check above.

The residual risk there is different in kind: **name drift**, where `sl-demo-1`
is held by a stale device and the rebuilt VM becomes `sl-demo-1-1`. That is
partially defended — the VM records a mismatch at
`/var/lib/signalloom/tailscale-name-mismatch` — but the marker is explicitly
advisory. Its own comment says callers "must not treat 'empty' as 'the node name
is verified'", and it is read over SSH, a different channel from the HTTPS path
an operator actually uses. An operator who only opens the URL consults nothing.

So: the tunnel path is now defended by provenance, the tailnet path by testimony
plus unique naming, and **neither defends the other**.

### 3c. What was made path-agnostic, and what could not be

The ask was to avoid a second copy of the identity model on a second path,
because drift in an identity check is the failure it exists to stop. The answer
splits cleanly, and the split is the useful part:

**Ownership cannot generalise.** `assert_tunnel_is_ours` attributes a socket on
*this* machine to a process *we* started. The tailnet path has no such socket —
the connection goes over the tailnet to a remote node. Anything claiming to
generalise it would be a different mechanism reusing the name, which is worse
than two honest mechanisms.

**Far-side identity does generalise, and it already existed** — inline in
`cmd_ts_test` R3, coupled to that command's own reporting helpers. It is now
extracted as `assert_far_side_lane_identity`, in the same file, so there is one
definition of the rule available to every path rather than one per transport.
`connect` and `public` call it; **`cmd_ts_test` has NOT been changed** — its
owner should switch R3 to call the shared primitive, which is a small change
this work deliberately did not make in someone else's command.

**It returns three values, and the third is the whole reason it is safe to share.**

| | | |
|---|---|---|
| `0` | VERIFIED | the far side named this lane's origin |
| `1` | MISMATCH | it named a different one — fatal |
| `2` | CANNOT-VERIFY | the origin cannot distinguish lanes, so a match proves nothing |

Without the third, sharing this check would have been actively harmful. Over IAP
the origin is `http://localhost:<port>` and every lane defaults to the same port,
so `got == want` holds *no matter which lane answered*. A naive reuse would have
returned VERIFIED for a hijacked socket — converting "we do not know" into "we
have confirmed", which is the worst outcome available to an identity check
because every downstream reader now believes the lane was checked.

An origin is treated as lane-distinguishing only if the lane key appears in it.
That is deliberately a property of the origin rather than a denylist of known-bad
hosts: the question is not "is this localhost" but "could this string have come
from another lane".

MISMATCH is fatal; CANNOT-VERIFY is a warning. That asymmetry is a judgement, not
a shrug — on the default IAP origin, CANNOT-VERIFY is the *normal* state today,
and failing on it would refuse every correct single-lane run. Ownership is what
actually defends that path; this becomes load-bearing the moment the local port
is per-lane, which is the other reason to take optimisation 4.

**Two mutations in this area were wrong before they were right**, and both
mistakes are the same shape as the bug being guarded. Neutering the
distinguishing test does **not** produce a vacuous pass on its own — control
falls through to the empty-issuer branch, which also returns CANNOT-VERIFY, so
the suite stays green and the mutation looks caught while nothing was tested.
Producing the vacuous pass needs the mutation *and* an issuer that echoes the
origin. The standalone proof therefore mutates the *reporting* of the third
verdict, and the in-suite test supplies the echoing issuer to mutate its
*production*.

The single change that would let one check cover both transports without any of
this is still the nginx lane-identity header.

## 4. The reaper — CLASHES (latent). NOT fixed; see why

**Verdict: CLASHES, but it cannot fire on its own today.**

`scripts/ci/gcp-tf-reaper.sh` has six safety gates and they are all about
*entitlement* — is this instance really a CI lane (`ci-lane` label present,
well-formed, `kind = ci`, `environment` agreeing, no demo markers, not a
protected runner). Every one is sound and covered by a ten-mutation proof.

**None of them is about activity.** Past the gates the only question is uptime:

    if [ "$age" -lt "$IDLE_MINUTES" ]; then ... keep ... fi

`IDLE_MINUTES` defaults to 45. So **nothing protects a lane that is mid-test.** A
CI lane whose legitimate run exceeds 45 minutes is suspended, and the test dies
as a lost SSH session — which will read as a product failure, not as a reaper.

The script is honest about resting on one premise, in its own header: *"gcp-tf-ci.sh
suspends on pass, on fail, and on interrupt, so a lane still RUNNING well past the
threshold is by construction a lane whose owner is gone. The threshold must
therefore sit comfortably above the longest legitimate run."*

**Whether 45 minutes still sits comfortably above the longest legitimate run is
UNKNOWN**, and it is the thing to settle before scheduling the reaper. Under
four-lane contention — shared project quota, shared network, four estates pulling
images at once — runs get longer, and the premise was written for a single lane.
Settling it needs a timed cold `gcp-tf-up`, which is an apply, which this work was
explicitly not permitted to run.

**It is definitively unwired, and an absent search result is a claim, so both
halves were checked with a positive control.**

*Cloud half.* `gcloud scheduler jobs list --project sl-port-over-sandbox` does not
return an empty list — it returns:

    Cloud Scheduler API has not been used in project sl-port-over-sandbox
    before or it is disabled.

That is stronger evidence than an empty list. An API that has never been enabled
on the project cannot be running a job on it.

*Code half.* `git grep -ln gcp-tf-reaper` returns the script, its mutation proof,
`terraform/CONTRACT.md`, `WIRING.md`, and the terraform files that define the
`ci-lane` label. **No Makefile, no workflow, no unit, no timer.** The positive
control matters here: the same search for `preflight.sh` — a script known to be
invoked — returns `Makefile` at the top. So the method demonstrably finds
Makefile invocations when they exist, and it finds none for the reaper.

`f-identity-ci.md` §ISC-194 predicted this: *"until then the reaper only runs when
somebody runs it"*. So the present-day risk is "somebody runs the reaper during a
long parallel session", not "a lane vanishes unattended".

### 4a. What the unwired reaper costs — an estimate, with its basis

**Measured facts.** `ci_idle_suspend_minutes` defaults to `30` and is not
overridden in `deploy/gcp/sl-port-over-sandbox.tfvars`. Its own validation message
reads *"or the lane never suspends and the estate bills forever"*. On 2026-08-20
`sl-ci-1-vm` had been RUNNING for **4.67 hours** against that 30-minute budget —
roughly 4.2 hours of billed idle on one lane, in one observation.

**The hard number, which needs no pricing assumption:** at `n2-standard-8`, a CI
lane left up past its declared budget burns **8 vCPU-hours per hour**. The two CI
lanes running continuously for a 30-day month is **11,520 vCPU-hours** that the
lanes' own configuration says should not have been spent.

**The money, which is an estimate and should be checked against the billing
console before anyone quotes it.** Basis: N2 list price, us-east4, on-demand,
~\$0.031611/vCPU-hour and ~\$0.004237/GB-hour, giving ~\$0.3885/hour for an
`n2-standard-8` (8 vCPU + 32 GB). Rounded, per 30-day month:

| | compute | notes |
|---|---|---|
| 2 CI lanes, never suspended | **~\$560/mo** | the upper bound on what the unwired reaper costs |
| 4 lanes, never suspended | ~\$1,120/mo | demo lanes get `idle_suspend_minutes = 0` **by design**, so half of this is a deliberate choice, not a defect |
| 4 × 100GB pd-balanced | ~\$40/mo | at ~\$0.10/GB-month |
| 4 × Cloud NAT gateway | ~\$127/mo | at ~\$0.044/gateway-hour, excluding data processing |

So **~\$560/month is the honest ceiling on the reaper finding** — what the two CI
lanes cost if nobody ever remembers to suspend them, which is exactly what "no
scheduler" means in practice. The realistic figure is lower and depends entirely
on how often a human intervenes, which is not a number I can measure.

Two caveats stated rather than buried. A SUSPENDED instance stops vCPU and RAM
charges but still bills for its disks and for preserved memory, so the saving is
less than 100% of the compute line. And the demo lanes are excluded from the
saving on purpose — `idle_suspend_minutes = 0` for `kind = "demo"` is the design,
because a demo that suspends itself mid-demo is worse than one that bills.

**The connection to §0 holds, and it is the more interesting half.** Had the
reaper been running, ci-1 and ci-2 would have suspended on their own declared
30-minute budget and freed 16 vCPU — which is exactly what the failed `demo-2`
apply needed. The unwired cost control and the quota ceiling are the same finding
wearing two hats, and the link is sound because suspend demonstrably frees CPU
quota (32.0 → 24.0, measured). It would **not** have helped with the SSD ceiling,
for the same reason: suspend does not free disk.

**Not fixed, deliberately.** The right fix is an activity signal — a lease or
heartbeat a running test holds, which the reaper checks as a seventh gate. That is
new machinery, not a surgical edit, and it lands in a script whose every existing
gate is pinned by a mutation proof. Raising rather than doing. **This is the
thing to build before F6 schedules the reaper**, and scheduling it without one
converts a latent clash into a live one.

## 5. `ci_idle_suspend_minutes` — published, documented, and never read

**Verdict: dead metadata. A doc-code divergence, not a clash.**

`terraform/modules/compute/main.tf:160` publishes `idle-suspend-minutes` on every
CI instance, and `terraform/environments/variables.tf:231` says why:

> *"Published on the instance so `scripts/ci/gcp-tf-reaper.sh` reads each lane's
> budget off the lane rather than carrying a duplicate constant."*

**The reaper does not read it.** It carries exactly the duplicate constant the
description says it avoids — `IDLE_MINUTES="${GCP_TF_REAPER_IDLE_MINUTES:-45}"` —
and `list_lanes` never requests instance metadata at all. There is no VM-side
agent reading it either; grep finds no consumer anywhere in the repo.

So `COMPUTE-RULE-12-CI-IDLE-BUDGET` and `COMPUTE-RULE-14-IDLE-SUSPEND` validate a
value that changes nothing, and per-lane budgets set in tfvars are inert. This is
the shape where a correct comment guards incorrect code: the description is what
makes the gap invisible, because anyone checking asks the variable and is told
the reaper reads it.

**Not fixed, deliberately, and it is the smaller half of §4.** The fix is to
append a metadata column to `list_lanes` — the sanctioned extension shape, since
that function's own comment notes the label columns are *appended* so short rows
degrade to empty and fail closed — and resolve the per-lane budget with the
constant as fallback. It is genuinely small. It was left because it belongs with
the activity-signal work in §4: making the budget live without making it
*activity-aware* just makes a lane suspendable at a number somebody set months
ago, which is not obviously better than a constant everyone knows is a constant.

## 6. The Dex origin claim — SAFE across lanes

**Verdict: SAFE.** `dex_origin` defaults to invoking the delivered copy of
`scripts/lib/dex-origin.sh` **over SSH on the lane's own VM** (`remote_run`), so
the origin lease is per-lane cluster state. There is no shared local file, no
shared kubeconfig, and no ambient current-context to get wrong —
`GCP_TF_DEMO_DEX_ORIGIN_CMD` overrides to a local command only for tests.

The prior finding this repo already carries — that `current` falls back to the
baseline and so is never empty, making "non-empty means held" refuse every idle
cluster — is fixed in the shipped code: `require_no_conflicting_origin` keys on
`holder` (the method), not on `current`. Confirmed at
`scripts/gcp-tf/demo-up.sh` and covered by the SEAM tests.

**But it amplifies §3 rather than mitigating it.** Every lane claims the *same
origin string* `http://localhost:30754`, because `iap_origin()` is built from the
colliding local port. Four clusters can each hold that lease simultaneously and
none can see the others. The per-lane isolation that makes this safe is exactly
what makes it unable to detect the collision.

## 7. Shared read-only inputs — SAFE

`deploy/gcp/deploy-sa` is read once through `sed` in a `$(shell ...)` at parse
time. The tfvars is passed as `-var-file` and never written. Neither is opened for
writing on any path. The handoff is per-lane by construction
(`GCP_TF_HANDOFF_FILE = deploy/gcp/$(ENV).handoff.json`) and the plan file is
per-lane inside the per-lane data dir.

## 8. Regional disk quota — CLASHES. HARD WALL. Cannot be fixed from this repo

**Not on the candidate list, and it is the one that stops four lanes today.**

Measured on `sl-port-over-sandbox`:

    SSD_TOTAL_GB: usage=400.0  limit=500.0
    CPUS:         usage=0.0    limit=200.0
    N2_CPUS:      usage=32.0   limit=200.0
    INSTANCES:    usage=3.0    limit=24.0
    IN_USE_ADDRESSES: usage=0.0 limit=8.0

CPU and instance count have plenty of headroom. Disk does not. All boot disks are
`pd-balanced`, which bills against `SSD_TOTAL_GB`, not `DISKS_TOTAL_GB`:

    sl-ci-1-vm    100GB
    sl-ci-2-vm    100GB
    sl-demo-1-vm  200GB
                  ---- 400GB of a 500GB limit

demo-2 is `boot_disk_gb = 200`. **400 + 200 = 600GB against a 500GB limit — short
by 100GB.** The four lanes cannot be up simultaneously as currently sized.

**Suspending does not help.** A SUSPENDED instance keeps its disk and therefore
its quota. Only `destroy` frees it — which is precisely why the hot-cold lane
strategy does not buy headroom here.

Three ways out, best first:

1. **Raise `SSD_TOTAL_GB` in us-east4 to 1000GB.** The real fix; 600GB with room
   for a fifth lane. Needs a human on the GCP console.
2. **Move ci-1/ci-2 to `pd-standard`** — frees 200GB of SSD quota immediately
   (`DISKS_TOTAL_GB` is at 32 of 4096). Costs CI throughput on image pulls, which
   is most of what a kind estate does.
3. **Drop demo-2 to `boot_disk_gb = 100`** — lands exactly on 500/500 with zero
   headroom, on the `n2-standard-16` lane most likely to want the space.

---

## The regression tests, and why they are not decoration

`test/terraform-demo-driver.bats` § PARALLEL — eight tests. The suite's own
`probe-ok` stub is why this bug survived: it answers "bound" unconditionally, so
no existing test could distinguish "my tunnel bound" from "another lane's tunnel
is listening". Setup now pins `GCP_TF_DEMO_PREFLIGHT_PORT_PROBE` to a deterministic
`port-free` stub, so the suite is not hostage to whatever is on port 8080 on the
runner — previously that would have been green on a laptop and red on a developer
running anything there, and neither result would have been about the driver.

A suite that asserts *refusals* is the classic shape that passes for the wrong
reason: any unrelated breakage also produces a non-zero exit. So
`test/lane-parallel-port-mutation-proof.sh` mutates the **real** driver and
requires the **real** suite to go red **by test name**, restoring through an EXIT
trap and refusing to start if a previous run left a sentinel. Six mutations:

| | mutation | what it would otherwise hide |
|---|---|---|
| M1 | connect's port guard deleted | the original bug, exactly |
| M2 | public's port guard deleted | one call site guarded says nothing about the other |
| M3 | guard still called, probe test inverted | a guard that is present to every grep and never fires |
| M4 | guard moved below the Dex claim | still refuses — after mutating this lane's issuer |
| M5 | escape hatch dropped from the message | a dead end, whose fix is to delete the guard |
| M6 | the two probes collapsed onto one variable | refuses every valid single-lane run |
| M7 | connect's ownership check deleted | the hijack, once a per-lane port hides the collision |
| M8 | public's ownership check deleted | a health probe that certifies the wrong lane |
| M9 | unattributable socket treated as ours | fail-open on every host without `ss` |
| M10 | ancestry walk collapsed to `pid = want` | rejects every REAL tunnel, while the suite stays green |
| M11 | connect's far-side identity assertion deleted | the shared layer, invisible on an origin that cannot distinguish lanes anyway |
| M12 | public's far-side identity assertion deleted | the same, on the path that also publishes |
| M13 | CANNOT-VERIFY reported as confirmation | "we do not know" announced as "we have confirmed" |

M3, M4, M9 and M10 are the ones worth having. M1/M2/M7/M8 are deletions, which
review catches; the other four leave a guard that *looks* correct.

**Two of these were NOT PROVEN on first run, and both were faults in the tests
rather than in the guards.** Recording them because each is a shape this repo
keeps meeting.

- **M8 passed against a mutant.** The public test asserted only "non-zero exit,
  and no `HEALTH:` line" — and with the ownership check deleted, public still
  exits non-zero (its health probe fails against the stub) and still never prints
  `HEALTH:`. A refusal test satisfied by *any* refusal. Fixed by asserting the
  positive string only the ownership check emits.
- **M10 could not be seen at all.** The `owner-ours` stub returns a pid *equal*
  to `tunnel_pid`, because `env` execs the stub and it keeps the pid — so the
  direct comparison succeeds and the ancestry walk is never entered. The suite
  was structurally blind to a mutation that would break every real tunnel. Fixed
  by having the stub also record a genuine child pid, and asserting the
  descendant case explicitly.

The harness itself also produced one false NOT PROVEN, for a reason worth
recording: on its first run the author was editing the Makefile and running
`make` in the same worktree while it had the driver mutated. Two agents in one
checkout is the very hazard this branch audits. The harness now says it must run
alone.

Each `mutate` compares sha256 before and after and aborts if the tree did not
change, because a non-matching `sed` no-ops while printing success — which in a
proof harness ships as "every mutation was caught" against a tree that was never
mutated.

---

## Optimisations — separate from the correctness fixes above

Ranked. Take or leave independently.

1. **Schedule the reaper.** Up to **~\$560/month** at list price (§4a), for a
   script that already exists, already has six safety gates, and already has a
   ten-mutation proof that they can fail. It is the largest number in this
   document by an order of magnitude and the cheapest to collect. Two provisos,
   both from §4: it has **no activity protection**, so scheduling it without an
   activity signal converts a latent clash into a live one; and its 45-minute
   default is asserted, not measured. Build the lease first, or set the interval
   from a measured cold `gcp-tf-up` rather than from the current constant.
2. **Wire `ci_idle_suspend_minutes` to something.** Small in itself, but it is
   what makes (1) tunable per lane in tfvars rather than by editing a script, and
   it closes a doc-code divergence where the variable's own description names a
   consumer that does not exist (§5).
3. **Parallelism itself, once quota allows.** Four-lane wall-clock goes from the
   sum of the runs to the longest one. Gated by §0, and note that at exactly
   32/32 the estate has no room for the transient N+1 that a future
   `create_before_destroy` would introduce (§0a).
4. **A per-lane default local port.** Removes the flag from §3's escape hatch
   entirely; four `connect`s just work. Costs a decision on two contract tests
   that pin `localhost:8080` for the fixture lane. Small change, real convenience,
   needs sign-off rather than a side effect.
5. **`gcp-tf-up` runs `init -reconfigure` twice** — once inside `gcp-tf-plan` and
   again inside `gcp-tf-apply`, each a full backend re-init. Measured at roughly
   10s each against this backend. Real but small, and the second init is what
   `gcp_tf_assert_prefix` re-checks before an apply, so removing it trades a
   safety re-assertion for ten seconds. **Recommend leaving it.** Recorded so the
   next person costing it does not have to measure it again.
6. **A read-only provider `filesystem_mirror`.** Each lane materialises its own
   ~240MB provider tree — ~960MB across four. A `TF_PLUGIN_CACHE_DIR` is the
   obvious move and is the **wrong** one: Terraform documents it as not
   concurrency-safe, which is precisely the property needed here. A filesystem
   mirror is safe because it is read-only. Saves disk more than time — measured
   cold init+plan was 14-15s per lane with three running concurrently, so the
   download is not the bottleneck. Low value; listed because the obvious version
   of this idea is actively harmful.

## What could not be tested, and what would settle it

- **Whether 45 minutes exceeds the longest legitimate CI run under four-lane
  contention (§4).** Needs a timed cold `gcp-tf-up` on a CI lane while the other
  three are loaded. That is an apply; not permitted here. Until then the reaper's
  central safety premise is asserted, not measured.
- **A genuine four-lane concurrent apply.** Blocked by §8 before it is blocked by
  anything else — the fourth lane cannot get a disk. The concurrency experiments
  above used `plan`, which does everything an apply does up to and including
  taking the per-lane state lock, so the state-locking axis is covered; resource
  contention during simultaneous creates is not.
- **Two lanes contending for one lane's state lock.** Not run: the only way to
  hold a lock long enough is a real apply, and the orchestrator was mid-apply on
  demo-2 throughout. Per-lane prefixes mean per-lane lock objects, confirmed as
  four distinct `default.tfstate` paths, so the mechanism is sound by
  construction — but the failure mode of a contended lock is untested here.
