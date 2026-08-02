# Five feature worktrees — integration plan

Five feature tracks are being developed in parallel, each in its own git worktree off
`cc69fa1` (the FAIR engine convergence commit) on `feat/signal-loop-and-bootstrap-refactor`.

| Branch | Worktree | Scope |
| --- | --- | --- |
| `feat/theme-aware-mode-switch` | `~/src/.worktrees/osramp-demo/feat/theme-aware-mode-switch` | Live/Demo toggle respects the CSS theme switcher |
| `feat/crypto-productionise` | `~/src/.worktrees/osramp-demo/feat/crypto-productionise` | Ship SPIFFE→OpenBao proof API; EOL column; key-exchange → inventory link |
| `feat/network-tests-live` | `~/src/.worktrees/osramp-demo/feat/network-tests-live` | Live network test results; Scan Now button |
| `feat/afm-live-integration` | `~/src/.worktrees/osramp-demo/feat/afm-live-integration` | Run drill-down dropdown; real CubeSat data; live KubeSec AFM API |
| `feat/rbac-live-wiring` | `~/src/.worktrees/osramp-demo/feat/rbac-live-wiring` | RBAC importer + explorer live via API; deep AFM integration; docs |

All five live outside the repository, per the canonical worktree home
(`~/src/.worktrees/<repo>/<branch>`, slashes preserved as nested directories). An in-repo
`worktrees/` directory bleeds into bun, fd, rg and test runners — that is why none is used here.

## Predicted conflict surface

The five tracks are scoped to different pages, but four of them touch the same three shared files.
That is where the merge cost lives, and it is why the order below is not arbitrary.

| Shared file | theme | crypto | network | afm | rbac |
| --- | :---: | :---: | :---: | :---: | :---: |
| `src/api/demoMode.ts` | ● | ○ | ● | ● | ● |
| `src/api/client.ts` | | ● | ● | ● | ● |
| `src/api/afmApi.ts` | | | | ● | ● |
| `src/components/Sidebar.tsx` (routes) | | ○ | | ○ | ○ |
| `src/components/DemoToggle.tsx` | ● | | | | |

● likely edit ○ possible edit

`demoMode.ts` is the hot spot: four tracks need live-vs-demo behaviour, and every one of them was
briefed with the same non-negotiable — **live mode must fail visibly rather than silently falling
back to demo data**. Because the requirement is identical across all four, the conflicts should be
textual rather than semantic, which is the cheap kind.

## Merge order, and why

Least-coupled first, so each subsequent merge resolves against a base that already contains the
shared-file changes it will collide with. Merge into `feat/signal-loop-and-bootstrap-refactor`.

1. **`feat/theme-aware-mode-switch`** — smallest, styling only, touches `DemoToggle.tsx` which
   nothing else edits. Landing it first means every later branch's demo/live UI work is reviewed
   against the corrected theming rather than against hardcoded colours.
2. **`feat/crypto-productionise`** — self-contained page plus a new proof endpoint. Touches no other
   track's surface.
3. **`feat/network-tests-live`** — page plus a results endpoint and a scan trigger. First branch to
   make a real dent in `demoMode.ts` and `client.ts`; lands before the two heaviest so those resolve
   once, not twice.
4. **`feat/afm-live-integration`** — owns `afmApi.ts`. Must precede `rbac`, which builds on it.
5. **`feat/rbac-live-wiring`** — last, deliberately. It was briefed to integrate with AFM *through
   intermediate APIs*, so it consumes what track 4 establishes. Merging it before AFM would mean
   resolving `afmApi.ts` twice and reviewing an integration against an API that had not landed.

The dependency that fixes the tail of this order is real, not stylistic: **rbac depends on afm.**
The first three are genuinely independent and could be reordered if one of them is blocked.

## Merge procedure

For each branch, in the order above:

```bash
cd ~/src/cp/osramp-demo
git fetch origin --prune                       # local refs go stale silently
git merge --no-ff feat/<branch>                # --no-ff keeps the track legible in history
# resolve conflicts, then, before committing the merge:
cd d2-signalloom/apps/dashboard-signalloom && bun test && bun run typecheck
cd ~/src/cp/osramp-demo && make risk-check     # the FAIR engine gate must stay green
```

`--no-ff` is deliberate: each track should remain a readable unit in history, because these are
five separable features and a bisect wants to see them that way.

**Gate before each merge is committed** — all must pass, not just the dashboard suite:

- `bun test` and `bun run typecheck` in `dashboard-signalloom`
- `go test ./...` in `d2-signalloom/apps/policy-engine` (any track adding an endpoint touches Go)
- `make risk-check` at the repo root — artefacts validate, engine self-checks, report reproducible

**Do not** squash the five into one commit. They are five features with five different reviewers'
worth of surface area, and the security-relevant ones (RBAC live wiring, the scan trigger) need to
be reviewable on their own.

## After the merge

Each worktree is removed once its branch is merged and its tests are green on the integration
branch:

```bash
git worktree remove ~/src/.worktrees/osramp-demo/feat/<branch>
git worktree prune
```

A worktree whose branch is merged but which is left on disk is the usual cause of a stale checkout
being edited weeks later.

## Standing constraints given to every track

Recorded here so a reviewer can check the work against the brief rather than against taste:

- **bun always**, never npm/npx.
- **No GPG signing** on commits this session (`--no-gpg-sign`).
- **Match the surrounding code** — no new state library, table library or CSS approach.
- **Demo mode stays deterministic and offline.**
- **Live mode never silently falls back to demo data.** Fail visibly. The current AFM bug — demo and
  live returning identical data — is exactly what that rule exists to prevent.
- **No credentials in the frontend.** The browser never talks to the Kubernetes API directly.
- **State-changing actions are POST**, validated server-side, and constrained to known definitions
  (the Scan Now button must not become an arbitrary-target network probe).
- Accessibility: real `<button>`/`<a>` elements with accessible names; visible focus rings.
