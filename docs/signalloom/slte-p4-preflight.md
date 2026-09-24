# SLTE-P4-PRE — External PR Trigger Integration & GitHub Actions Preflight

| Field | Value |
|---|---|
| Card | SLTE-P4-PRE (kanban task `f204f`) |
| Base | `integration/slte-v0.1.0` @ `f827c5bd` |
| Subject | `fe-signalloom/src/webhook_triggers.py`, `environment_routing.py`, `scripts/eap/emit-eap-webhook.sh`, `d2-infra/components/ingress/webhook-httproute.yaml`, `fe-signalloom` deployment manifests |
| New artefacts | `fe-signalloom/src/tests/test_slte_p4_preflight_lifecycle.py` (13 pass + 14 strict xfail, all `raises=AssertionError`), `docs/signalloom/templates/signalloom-pr-preview.github-actions.yaml` |
| Verdict | **Audit: PASS** (complete, every claim probed). **Implementation audited: NO-GO as a security boundary.** 12 gap IDs (G1, G1b, G2–G6, G6b, G7–G10, §5), 10 of them pinned by 14 strict xfails. **P4-1 must not start until G1, G1b and G9 are fixed.** G1: a receiver built from this branch authenticates against a secret committed to git. G9: the environment control API it drives has no authentication at all. |

This preflight answers three questions before P4-1 builds the PR preview lifecycle engine:

1. How will external PR events be simulated and validated in acceptance tests?
2. How does the customer's webhook secret reach the CI runner and the receiver, and how is it rotated?
3. Does PR close or merge reliably tear the preview down, and is there a garbage-collection backstop?

## 1. Headline findings

1. **The two halves of the contract had never met.** `test_webhook_triggers.py` signs its own payloads and calls the app in-process through `TestClient`. `test_emit_eap_webhook.sh` only greps `--dry-run` text. The new E2E suite sends real emitter output over a socket to a live uvicorn receiver. The GitHub path works with a shared secret. The emitter's **generic** path is rejected every time (G2), and the emitter and server **default** secrets differ (G3). Both suites were green throughout.
2. **The deployed receiver authenticates against a secret in git (G1).** No manifest, kustomization, Terraform file or script injects `SIGNAL_LOOM_WEBHOOK_SECRET`, so the running pod falls back to `DEFAULT_WEBHOOK_SECRET = "signalloom-webhook-secret-2026-q3"` (`webhook_triggers.py:34`). A request signed with that literal returns **200** and provisions an environment (`test_gap_receiver_fails_closed_without_configured_secret`, run with `--runxfail`: `assert 200 in (401, 503)`). In effect, HMAC verification is bypassed for anyone who can read the repository.
3. **Previews are per customer, not per PR (G5).** The registry is keyed by customer hash. PR #2 gets `already_active` with PR #1's environment id, and closing PR #1 tears down PR #2's preview. P4-1's `sl-eap-{hash}-pr{N}` target needs a new key, not a new format string.
4. **Nothing reaps anything on this branch (G6).** `EnvironmentRecord.is_expired` (`environment_routing.py:258`) has no caller. An expired environment stays `ready`, is reported `already_active` on the next open or reopen, and a `synchronize` against it *extends* the lapsed lease. The "orphans are GC'd after 24 h" guarantee does not exist here. The sibling SLED board's `environment_lifecycle.py` (the reaper home audited in `sled-p2-preflight.md`) is **not present on this branch**.
5. **The GitHub endpoint has no replay defence (G4).** GitHub's `X-Hub-Signature-256` carries no timestamp, and `X-GitHub-Delivery` is read but never deduplicated. A captured `opened` delivery replayed after close provisions a fresh environment. The proposal's Pattern 3 (idempotent dispatch via a delivery-id cache) is unimplemented, and the 300 s replay bound applies only to `/generic`.
6. **The environment control API is unauthenticated (G9).** `environment_routing.py` declares no auth dependency on any route, and the dashboard nginx `location /api/` proxies `/api/v1/environments/*`. Without credentials, `GET /api/v1/environments/` lists every tenant's environments and `POST /{id}/teardown` destroys any preview. Observed: `assert 200 in (401, 403)` under `--runxfail`. **Webhook HMAC is moot while this stands**, because an attacker never needs the webhook. The suite's own guards already flag the neighbourhood as unowned: `test_tenant_isolation.py::test_the_route_sweep_covers_every_authenticated_api_route` and `test_audit_provenance.py::test_every_mutating_route_makes_an_audit_decision` both **fail on the base commit** and name these routes (G10).
7. **The dedicated webhook HTTPRoute is dead config.** `d2-infra/components/ingress/webhook-httproute.yaml` is referenced by no kustomization (`rg -n 'webhook-httproute' --glob '*.yaml'` returns only its own path). Webhooks already reach the receiver through the existing `signalloom-dashboard` route → nginx `location /api/` → `fe-signalloom-api:8000`. `validate-webhook-ingress.sh` passes only because it greps for strings in the file.

## 2. Prior-work verification table

| # | Artifact | Probe | Result |
|---|---|---|---|
| V1 | `src/webhook_triggers.py` (295 lines) | `wc -l`; Read | Present. HMAC-SHA256 verifiers use `hmac.compare_digest`; `/github` and `/generic` routers exist |
| V2 | API wiring | `rg -n webhook src/main.py` | `main.py:20` import, `main.py:44 install_webhook_triggers_api(app)`: **wired** |
| V3 | `src/tests/test_webhook_triggers.py` (6 tests) | `uv run … pytest tests/test_webhook_triggers.py -v` | **6 passed in 0.86s** |
| V4 | `scripts/eap/test_emit_eap_webhook.sh` (9 asserts) | `bash scripts/eap/test_emit_eap_webhook.sh` | **9 passed, 0 failed, rc=0**. All 9 are `--dry-run` string-presence checks; none sends a request |
| V5 | `scripts/eap/validate-webhook-ingress.sh` | `bash …` | rc=0. It is a presence grep that does not detect the orphaned route (finding 6) |
| V6 | Webhook HTTPRoute deployed | `rg 'webhook-httproute' --glob '*.yaml'` | **ABSENT** from every kustomization |
| V7 | Secret injection into the pod | `rg SIGNAL_LOOM_WEBHOOK_SECRET` across the repo, excluding the reader | **ABSENT**: only the reader and a card generator mention it |
| V8 | Expiry reaper | `rg 'is_expired\|reap' src --glob '!tests/**'` | **ABSENT**: `is_expired` has no caller; `environment_lifecycle.py` is not on this branch |
| V9 | Real emitter → real receiver (GitHub path) | new E2E suite | **PASS** for opened / synchronize / closed / reopened, tamper and wrong secret |
| V10 | Real emitter → real receiver (generic path) | `test_gap_generic_emitter_accepted_by_server --runxfail` | **FAIL** 401: contract drift (G2) |
| V11 | Is G1 live on the running cluster? | `kubectl -n fe-signalloom exec deploy/fe-signalloom -- …` on `kind-osramp` (read-only) | **Latent, not live.** The running image predates this branch (`python3 -c "import webhook_triggers"` → `ModuleNotFoundError`), and the pod env has 0 `SIGNAL_LOOM_WEBHOOK*` variables. G1 goes live the moment an image built from this branch is deployed with these manifests |
| V12 | Template workflow lint | `uvx --from actionlint-py actionlint`; `uvx zizmor --offline --persona auditor` | actionlint rc=0; zizmor **no findings** (after fixing 2 high + 3 medium, §7) |
| V13 | Full fe-signalloom suite | `uv run … pytest tests -q` | See §2a |

Re-run command for V3, V9 and V10, from `d2-signalloom/apps/fe-signalloom/src`:

```bash
env -u SIGNAL_LOOM_WEBHOOK_SECRET -u EAP_WEBHOOK_SECRET \
UV_CACHE_DIR=/home/andy/src/.worktrees/.uvcache \
uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist \
  --with-requirements requirements.txt \
  python -m pytest tests/test_webhook_triggers.py tests/test_slte_p4_preflight_lifecycle.py -v -rxX
# captured (final tree): 19 passed, 14 xfailed  (new file alone: 13 passed, 14 xfailed)
```

### 2a. Full-suite regression check

`uv run … pytest tests -q` over all of `fe-signalloom/src/tests`, final tree:

```
FAILED tests/test_audit_provenance.py::test_every_mutating_route_makes_an_audit_decision
FAILED tests/test_tenant_isolation.py::test_the_route_sweep_covers_every_authenticated_api_route
2 failed, 1493 passed, 83 skipped, 11 xfailed, 3 warnings in 241.41s
```

Both failures predate this card. They enumerate the production app's routes and name only `environment_routing.py` / `webhook_triggers.py` routes introduced by `8629b5f8` / `0c667d30`. This card adds no route and modifies no production file: `git status` shows three untracked additions only. They are recorded as gap G10, not fixed here. The 11 xfails are this card's strict gap tests as of that run. The three per-axis G2 xfails were added afterwards (after the Cato audit); the file-level run on the final tree is 13 passed, 14 xfailed, and the new tests touch only the emitter's `--dry-run` output.

## 3. How external PR events are simulated and validated

**The simulation harness** is `tests/test_slte_p4_preflight_lifecycle.py`. It starts uvicorn on an ephemeral port with `main:app` and `lifespan="off"`; the webhook path touches no database. Two real clients drive it, so each test covers both halves of the contract:

| Client | What it proves |
|---|---|
| `scripts/eap/emit-eap-webhook.sh github-pr …` without `--dry-run` | The emitter's GitHub-style signing is accepted by `verify_github_signature` over HTTP |
| The `send` step's `run:` script, extracted from the workflow template and run with `bash -c` | The script a customer runner executes is accepted by `verify_generic_signature`. The test also asserts that it supplies **exactly** the step's declared `env:` keys, so it exercises the template's real interface |

**Validation** reads state back through `GET /api/v1/environments/{id}` and the registry, not just the webhook's own response. For example, the sync test asserts that `expires_at` advanced by exactly 60 minutes.

**Evidence the harness can fail:**
- A mutation that changed the template's signing separator `.` to `:` made `test_template_send_step_accepted_by_live_verifier` fail (`1 failed`). The template was restored, verified by `cmp`.
- Each strict xfail was re-run with `--runxfail` and fails on the defect it names, not on a harness error (§5, "observed").
- Missing host tools (`curl`, `jq`, `python3`) make the tests **fail**, not skip.

**Wire-shape finding (O1):** rejected webhooks never carry the handler's `detail`. `api_compat.install_api_exception_handlers` (`api_compat.py:1344-1352`) rewrites every `HTTPException` other than 404 and 405 to `{"error":{"code":"request_error","message":"Request failed"}}`. A customer's CI therefore cannot tell a bad signature from an expired timestamp or a bad payload. P4-1 should raise `APIError` with distinct, non-leaking codes (`signature_invalid`, `timestamp_out_of_window`, `payload_invalid`).

## 4. PR lifecycle state machine — audited behaviour

| GitHub event | Handler behaviour (`webhook_triggers.py`) | E2E evidence | Correct? |
|---|---|---|---|
| `opened` | `registry.create(DEMO, ttl=120)`; on 409 → `already_active` (L152-173) | `provisioned`, env `ready` | ✓ for one PR. ✗ for a second concurrent PR (G5) |
| `reopened` | Same branch as `opened` (L149) | Fresh env id after close; old id stays `terminated` | ✓, **unless** the old env expired without being reaped: then `already_active` and a stale reference (G6) |
| `synchronize` | `extend_ttl(+60)` if not terminated (L175-183) | `extended_ttl`, `expires_at` +60 min | Partial. It extends expired leases (G6b), does not redeploy (P4-1 "hot reload"), and past the 72 h ceiling `extend_ttl` raises 400 → GitHub marks the delivery failed |
| `closed` (merged or not) | Teardown if not terminated (L185-193). `merged` is ignored | `torn_down`, then `already_terminated` on repeat (idempotent) | ✓ for one PR. ✗ it tears down *any* PR's preview for the customer (G5) |
| any other `X-GitHub-Event` | `ignored`, 200 | — | ✓ |
| Replayed `opened` | Re-provisions | `test_gap_replayed_github_delivery_rejected` | ✗ (G4) |

Tenant derivation (L133-135) uses `payload.repository.name`. It maps to `kurasi` if the name contains "kurasi", otherwise to `name.split("-")[0]`. Every tenant shares one global secret (`get_webhook_secret()` is called without `tenant_key`, L118 and L222), so **any holder of the global secret can provision or tear down any tenant's environment** by choosing the repository name. The per-tenant lookup `SIGNAL_LOOM_WEBHOOK_SECRET_{TENANT}` exists (L38-45) but is dead code (G7).

**Teardown guarantee today:** it is purely in-memory. `teardown()` flips a registry row; nothing de-registers a route, stops a Tailscale node, or deletes a namespace. The registry is process-local, and the deployment runs `replicas: 1` and `uvicorn --workers 1` (Dockerfile L37), so a pod restart loses every record. Any real infrastructure P4-1 attaches would then be orphaned with no record, and G6 leaves no reaper to collect it. **Teardown and GC must therefore be driven from durable state.**

## 5. Gap register — handed to P4-1 as strict xfails

| ID | Gap | Test (strict xfail) | Observed with `--runxfail` |
|---|---|---|---|
| G1 | Receiver fails **open** to `DEFAULT_WEBHOOK_SECRET` (literal in git) when no secret is configured, which is true of every shipped manifest | `test_gap_receiver_fails_closed_without_configured_secret` | `assert 200 in (401, 503)` |
| G2 | Emitter `generic` contract drifts on three axes: ISO-8601 vs epoch-int timestamp (`emit-eap-webhook.sh` L173), `ts:body` vs `ts.body` (L180), `sha256=` prefix vs bare hex (L203) | `test_gap_generic_emitter_accepted_by_server` | 401 envelope |
| G2a/b/c | The same drift, one axis per test, from the emitter's `--dry-run` output, so partial fixes are visible | `test_gap_generic_emitter_axis[epoch-timestamp, dot-separator, bare-hex-signature]` | each axis fails independently |
| G3 | Emitter reads `EAP_WEBHOOK_SECRET` (default `…-eap-webhook-secret-dev-2026-q3`, L17); server reads `SIGNAL_LOOM_WEBHOOK_SECRET` | `test_gap_emitter_honours_server_secret_variable` | 401 envelope |
| G4 | No `X-GitHub-Delivery` dedupe; GitHub path replayable forever | `test_gap_replayed_github_delivery_rejected` | replay → 200 `provisioned` |
| G5 | Environment keyed per customer, not per PR | `test_gap_concurrent_prs_get_isolated_previews` | PR #2 id == PR #1 id |
| G6 | No reaper; expired env reported `already_active` | `test_gap_expired_environment_is_not_reported_active` | `'already_active' == 'provisioned'` fails |
| G6b | `synchronize` resurrects an expired lease | `test_gap_sync_does_not_resurrect_expired_environment` | `extended_ttl` |
| G7 | Per-tenant secret lookup is dead code; tenant chosen by attacker-controlled repo name | *(design; covered by G1 fix + blueprint §7)* | — |
| G1b | An empty `SIGNAL_LOOM_WEBHOOK_SECRET=""` is used as-is (`os.getenv(K, DEFAULT)` returns `""`, not the default), so an HMAC keyed with the empty string verifies | `test_gap_empty_secret_is_refused` | `assert 200 in (401, 503)` |
| G9 | `/api/v1/environments/*` is unauthenticated: list all tenants, tear down any preview | `test_gap_environment_control_api_requires_authentication` (accepts 401/403/404) | `assert 200 in (401, 403, 404)` |
| G10 | Webhook and environment mutations write no audit event and sit outside the tenant route sweep | pre-existing failures `test_audit_provenance.py::test_every_mutating_route_makes_an_audit_decision` (6 routes incl. both webhook receivers) and `test_tenant_isolation.py::test_the_route_sweep_covers_every_authenticated_api_route` | red on base `f827c5bd` |
| G8 | `/generic` does `int(ttl_minutes)` and builds `ProvisionRequest` inside the handler → HTTP 500 on `"abc"` or `100000` | `test_gap_generic_bad_ttl_is_client_error[abc,100000]` | `assert 500 < 500` |

Strict mode means that when P4-1 fixes a gap, the test XPASSes and **fails the run** until the marker is removed. A fix cannot land without its assertion becoming live.

## 6. Secret injection and rotation

**Current state:** there is no injection. `base/secrets.yaml` holds demo-only credentials (its own header: "Production secrets … deliberately out of scope for this TRL 2 Kind baseline"), and none of them is a webhook secret. **Do not add one there.** That would commit a customer token to git, which is out of scope for this card and a G1 repeat.

**Required design (P4-1):**
1. The receiver reads `SIGNAL_LOOM_WEBHOOK_SECRET_<TENANT>` from a Secret `signalloom-webhook-secrets` created out of band (OpenBao-synced or `kubectl create secret`). The Secret is referenced with `secretKeyRef` and `optional: false`, so a missing secret stops the pod from starting. Delete `DEFAULT_WEBHOOK_SECRET` and fail closed (503) if resolution fails at request time (G1).
2. Resolve the tenant from **which secret verified the request**, never from the payload (G7). With N tenants, try each tenant's current and previous secret with `compare_digest`; N is small.
3. The customer stores the same value as the GitHub Actions secret `SIGNALLOOM_WEBHOOK_SECRET` (template) or as the repository-webhook secret (native mode). It never appears on argv: the template signs in Python from the environment.

**Rotation procedure (dual-secret overlap):**

| Step | Actor | Action |
|---|---|---|
| 1 | ControlPlane | Generate a new secret (`openssl rand -hex 32`) and write it as `…_<TENANT>_NEXT` alongside `…_<TENANT>` |
| 2 | Receiver | Accept a signature valid under **either** key; log which key verified it |
| 3 | Customer | Update the repository/Actions secret to the new value |
| 4 | ControlPlane | When logs show zero verifications under the old key for 24 h (or at a hard deadline of 7 days), promote `_NEXT` → current and delete the old key |
| 5 | Both | On suspected compromise, skip the overlap: replace the key immediately and accept failed deliveries until the customer updates |

The receiver currently supports exactly one key, so step 2 is P4-1 work.

## 7. Customer integration blueprint (kusari)

There are two supported modes. **Mode B is the recommended default for the pilot.**

| | Mode A — native GitHub repository webhook | Mode B — GitHub Actions workflow (template) |
|---|---|---|
| Endpoint | `/api/v1/webhooks/github` | `/api/v1/webhooks/generic` |
| Signed by | GitHub (`X-Hub-Signature-256`) | Customer runner (`X-SignalLoom-Timestamp` + `-Signature`) |
| Replay bound | **None today** (G4; needs delivery-id dedupe) | 300 s timestamp window |
| Reachability | GitHub's egress ranges must reach the receiver, so it needs a **public** route (Funnel or public Gateway) | Runner can join the tailnet (`tailscale/github-action`, ephemeral `tag:signalloom-ci`) or use a public route |
| PR metadata | Full GitHub payload | Template sends `pr_number`, `pr_action`, `merged`, `head_sha`, `repository`, `delivery_id` (ignored by today's handler; P4-1 consumes them) |
| Sync semantics today | TTL extend | `provision` → `already_active` (no extend: the generic vocabulary has no `extend`) |

**Network (failure mode "runner has no tailnet access"):** `build_environment_urls` returns `https://sl-eap-<hash>.tailscale` and `https://sl-eap-<hash>.ts.net`. Neither resolves from a GitHub-hosted runner, and neither is a valid MagicDNS FQDN (real names are `<host>.<tailnet>.ts.net`). The receiver sits behind the cluster Gateway `https` listener, which admits routes from `fe-signalloom`. The `http` listener is `from: Same` and would reject the orphaned webhook route. A hosted runner therefore needs either (a) a public hostname on the Gateway serving only `/api/v1/webhooks/*`, or (b) the tailnet-join step in the template. Option (b) keeps the receiver off the internet and is the template's switch `vars.SIGNALLOOM_RECEIVER_ON_TAILNET`.

**Template:** `docs/signalloom/templates/signalloom-pr-preview.github-actions.yaml`. Its properties are asserted by `test_template_static_security_properties` and `test_template_send_step_accepted_by_live_verifier`, and it lints clean under actionlint and zizmor (auditor persona):
- `pull_request` (not `pull_request_target`) on `opened, reopened, synchronize, closed`. The first draft used `pull_request_target`, and zizmor flagged it `dangerous-triggers` (high). Previews are same-repository only, so `pull_request_target` added pwn-request risk for no benefit. Under `pull_request`, fork runs get no secrets and fail closed by construction, and the job-level `if:` skips them cleanly. The workflow never checks out PR code.
- `permissions: {}` (the job never uses `GITHUB_TOKEN`). Secrets are scoped to a GitHub Environment `signalloom-preview`, so the customer can add protection rules (zizmor `secrets-outside-env`). `concurrency` is keyed per PR number with no cancellation, so an `opened` never races its own `closed`.
- **Do not put required reviewers or a restrictive deployment-branch rule on `signalloom-preview`.** The same environment gates the `closed` run, so an approval gate would hold every teardown until someone approves, orphaning previews (G6 means there is no reaper to catch them). Use the environment for secret scoping only, or split it into a gated `-provision` and an ungated `-teardown` environment.
- `tailscale/github-action` is pinned to `6cae46e2d796f265265cfcf628b72a32b4d7cade` (tag `v3.3.0`, resolved by `git ls-remote`; `oauth-client-id`, `oauth-secret` and `tags` inputs confirmed in `action.yml` at that commit).
- Event fields reach the script only via `env:`. `${{ }}` never appears inside `run:` (script-injection defence).
- It signs the exact bytes sent (the trailing newline is stripped before signing), and it retries only transient errors. `--retry-all-errors` was removed after the live test showed it retried a 401 four times.

**Reopen and merge:** `reopened` maps to `provision` and `closed` to `teardown` whether merged or not. `merged` is forwarded for audit. Previews for merged PRs are destroyed; there is no "keep after merge" mode.

## 8. Other observations

- **O1:** error envelope sanitisation hides the rejection reason (§3).
- **O2:** naming drift. The proposal's executive summary and work decomposition say pilot customer **`kusari`**; the cards, code, tests and canonical hash vector (`6f82ad81`) use **`kurasi`**. The hash is derived from the name, so this is not cosmetic. Confirm the intended tenant before P4-1 bakes `sl-eap-6f82ad81-pr42` into fixtures and PR comments.
- **O3:** the customer hash uses the public default salt `signalloom-eap-salt-2026-q3` (no manifest sets `SIGNAL_LOOM_EAP_SALT`), so hostnames are enumerable from customer names. That is out of scope here (SLEA), noted for P4-GOV.
- **O4:** the emitter's Python fallback (`emit-eap-webhook.sh` L39) interpolates the secret and payload into Python source (`b'$secret'`, `'''$data'''`), and `--pr` is interpolated unquoted into JSON. The emitter is a test tool, but it should not be copied into customer pipelines. The template replaces it for that purpose.
- **O5:** there are two copies of the proposal. The canonical one is the Obsidian vault note, which carries the RESET errata block. `~/src/cp/osramp-demo/docs/Proposal — … (2026-Q3).md` is untracked and stale (no RESET block), yet `scripts/eap/generate_and_apply_slte.py` hashes *that* copy as `proposalContractSha256`.

## 9. Hand-off checklist for P4-1

0. **Precondition:** authenticate `/api/v1/environments/*` and put it under the tenant route sweep and audit decision (G9, G10). Until then, nothing in 1–7 is a security control.
1. Remove `DEFAULT_WEBHOOK_SECRET`; fail closed on unset **and empty** (G1b); per-tenant secrets with dual-key rotation (G1, G7) → flip G1 xfail.
2. Key environments by `(customer_hash, pr_number)`; teardown only the closing PR's preview (G5).
3. Durable delivery-id dedupe on both endpoints (G4). The template's `curl --retry` resends the same signed request after a 5xx; today the registry's 409 → `already_active` makes that accidentally idempotent, and per-PR keying (item 2) removes that accident. **Land dedupe with or before item 2.** Treat a duplicate as `200 {"action_taken":"duplicate_delivery"}` so GitHub does not retry.
4. Reaper or expiry-on-read so that expired ⇒ not active and sync cannot resurrect (G6, G6b); coordinate with SLED's `environment_lifecycle.py` rather than building a second reaper.
5. Validate the generic payload with a Pydantic model at the boundary, returning 4xx (G8), and add `pr_number` and `extend` to the generic vocabulary so Mode B can express sync.
6. Align the emitter with the server contract (G2, G3), or retire its generic subcommand in favour of the template's signing code.
7. Delete or wire `webhook-httproute.yaml`. If wired, give it `sectionName: https` and an explicit hostname, and replace `validate-webhook-ingress.sh` with a `kustomize build | yq` assertion.
