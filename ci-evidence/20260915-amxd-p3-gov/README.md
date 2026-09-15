# AMXD-P3-GOV — Phase 3 certification evidence

Certified `integration/amxd-v0.1.0` at `14d56cef21f4e513e806d8869ce598a25b8341b1`.
Full reasoning and the property→command table are in the proposal under
`#### Errata — AMXD-P3-GOV`.

## Artefacts

| File | What it proves |
| :--- | :--- |
| `stage3-composed-match-and-mismatch.png` | Real Chromium render of the composed Stage 3 view. Panel A is the happy path (Open FDs = `Unavailable` / `N/A`, integrity badge `MATCH` in teal). Panel B is the tamper breach (badge `MISMATCH` in red, red row tint, computed SHA `deadbeef98fc1c14…` in bold red). Also the primary evidence for **Defect G1** — the `ZeroPayloadInspector` below each panel renders unstyled with horizontal overflow. |
| `vitest-full-summary.txt` | Full dashboard suite, not the `demos/` subset: 174 files, 3,329 passed, 3 skipped, 0 failed. |

## Manifest digest at certification time

```
183b788007e4adfe116e792893ccc814f5e66acfa68dbff067c9e2d71a239b34
```

Verified three independent ways — `generate-agentmaxxing-allowlist-manifest.mjs --check`
(exit 0), `sha256sum` on `filter.py` directly, and the committed `filter_sha256`
field. A later phase can detect drift by comparing against this value.

## Reproducing the screenshot

The screenshot was taken with a temporary harness entry that was deleted after
capture, so the tree stays clean. To regenerate:

1. Add a Vite entry rendering `ConfinementTelemetryPanel` twice — once with
   `HAPPY_PATH_PRESET` and a `status: 'match'` artifact, once with
   `TAMPER_BREACH_PRESET` and a `status: 'mismatch'` artifact.
2. `npx vite --port 5199 --strictPort`
3. `playwright screenshot --full-page --viewport-size=1400,2400 --wait-for-timeout=2500 http://localhost:5199/<entry>.html out.png`

The live `/demos/agentmaxxing` route sits behind `ProtectedRoute` and needs
authentication, which is why a harness entry was used rather than the route.

## Staleness path (reproduced on the merged tree, not only in a fixture)

```
$ printf '\n# probe\n' >> d2-signalloom/apps/agentmaxxing-host-sensor/filter.py
$ node scripts/generate-agentmaxxing-allowlist-manifest.mjs --check
[allowlist-manifest] ERROR: Manifest is STALE relative to filter.py.
  - filter.py SHA-256 current:  95e3875ebf1421efeb33a0404822a4f1328018328346cc205a7a2b6ce2b10edb
  - Manifest filter_sha256:     183b788007e4adfe116e792893ccc814f5e66acfa68dbff067c9e2d71a239b34
EXIT=1
```

`filter.py` was restored immediately and its digest re-verified identical to the
pre-mutation value. `git status --porcelain` was clean afterwards.
