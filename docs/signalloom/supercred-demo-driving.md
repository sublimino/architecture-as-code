# Driving the SuperCredential demo

Two supported paths, one script. The browser buttons and the make targets both
execute `scripts/supercred-demo.sh`; neither simulates anything and neither is
a fallback for the other. Pick by audience, not by capability.

| | UI path | make path |
|---|---|---|
| Who it is for | An instructor presenting to a room | An engineer at a terminal, or CI |
| Where the phase runs | `supercred-demo-runner` pod, in-cluster | Your shell, against your kubeconfig |
| Who may drive it | Superadmin only, enforced server-side | Anyone with cluster write access |
| Log output | Streamed into the page | stdout |
| What the audience sees | Identical — both change the same cluster | Identical |

The two are interchangeable mid-demo. Starting phases 1–3 from a shell and then
switching to the page for the stun works, because the page reads cluster state
rather than remembering what it started.

## UI path

1. Open **SuperCredential Demo** (`/supercred`) in one window, and **Agents**
   (`/agents`) in a second window on the screen the audience is watching.
2. In the demo window, press **Refresh clients** to pull the live estate. If a
   rehearsal left residue, press **Reset demo** and confirm — reset is a
   first-class control, not a recovery path.
3. Press each phase button in turn. The run status and the streaming log appear
   below the buttons; every control locks while a run is in flight, because the
   demo mutates one shared cluster and the runner serialises runs.
4. Follow each phase's **Show this on →** link to the customer page where that
   phase's effect lands: 1 → Agents, 2 → Credential Inventory, 3 → Compliance,
   4 → Agents, 5 → Audit Trail.
5. At phase 4, stop talking and let the second window do the work. It shows
   **STUNNED — CREDENTIALS REVOKED** with the reason and a timestamp, on its own
   poll interval (`LIVE_POLL_MS`, `src/api/pollInterval.ts`). Nobody reloads
   anything.

### If the buttons are disabled

The panel says why and shows the equivalent `make` command for each phase. The
two causes are:

- **`script_available: false`** — the runner is up but cannot see
  `scripts/supercred-demo.sh`. Check `SUPERCRED_DEMO_CWD` on the Deployment.
- **The runner is unreachable** — `/demo-api/` returned an error. Check the
  `supercred-demo-runner` rollout and the NetworkPolicies.

**Refresh clients** deliberately stays enabled in both cases: reading the estate
needs no script.

## make path

```bash
make demo-signalloom-supercred-1     # deploy agent, SPIRE entry, OpenBao secrets
make demo-signalloom-supercred-2     # SPIFFE -> OpenBao -> cardvault credential chain
make demo-signalloom-supercred-3     # compliance scan finds the missing securityContext
make demo-signalloom-supercred-4     # stun: revoke credentials, verify denial
make demo-signalloom-supercred-5     # teardown + assert clean
make demo-signalloom-supercred-all   # 1 -> 5 back to back
```

The dashboard reflects each of these exactly as if the button had been pressed,
so the second window works for this path too — which is the point of driving
both from one script.

Repeatability harness:

```bash
./scripts/supercred-e2e.sh iterate 1   # one clean cycle, asserts a clean teardown
```

## Who can drive it

Controls are superadmin-only and the check is **server-side**
(`apps/fe-signalloom/src/superadmin.py`), derived from the validated Dex JWT and
never from a header, query parameter or request body. Hiding the buttons is
presentation; the runner enforces access itself.

| Route | Required |
|---|---|
| `POST /demo-api/runs` | superadmin |
| `POST /demo-api/reset` | superadmin |
| `GET /demo-api/status` | superadmin — carries the privileged run history |
| `GET /demo-api/runs/{id}/log` | superadmin — raw script output |
| `GET /demo-api/steps` | any authenticated user |
| `GET /demo-api/runs/{id}` | any authenticated user — one phase's status |

All demo **evidence** — the stun on Agents, the finding on Compliance, the
record on Audit Trail — is visible to any authenticated user and is behind no
superadmin gate at all. That is what makes the second window worth showing.

Two Dex identities exist for this
(`infra/inf-signalloom/base/dex.yaml`): `demo-user@signalloom.local` is the
instructor and is a superadmin; `viewer@signalloom.local` authenticates cleanly
and is not. The viewer exists so the gate can be proven against the deployed
system rather than only in a unit test.

## Verifying it still works

```bash
# The authorization boundary, live, with real Dex tokens
bats d2-signalloom/test/supercred-demo-api.bats

# The two-window demo itself, in two real browser contexts
./scripts/acceptance-test.sh supercred-two-window.spec.ts

# The 1 -> 5 cycle and its clean teardown
./scripts/supercred-e2e.sh iterate 1
```

## Related

- `docs/signalloom/stun-under-flux.md` — why the stun survives Flux reconciliation
- `docs/signalloom/dashboard-superadmin-themes-importer.md` — the superadmin visibility flag
- `docs/signalloom/dex-oidc-design.md` — token shape, issuer, and the subject map
