# Runbook — looping the Jev exploratory bot over the whole dashboard surface

**Status:** current. Written 2026-10-05. Every command below was executed on
branch `slaws2-jev-loop-wc`; output is pasted verbatim, not illustrative.

## When to use this

`make test-bot` explores **one** area of **one** URL, defaulting to the shared
Tailscale deployment. Use `make test-bot-loop` instead when you want either of
the two things that one cannot give you:

- **whole-surface coverage** — every route in `App.tsx`, with a report naming
  which routes were visited and which were not
- **isolation** — a dashboard this run starts and tears down itself, on a port
  no other suite reserves, so it can run in a loop while the acceptance,
  apikey and e2e suites are running

```bash
make test-bot-loop MOCK=true N=1            # one pass, offline, own dashboard
make test-bot-loop MOCK=true N=10           # ten passes
make test-bot-loop URL=https://dashboard.osramp.acme.local:30754 N=1
bats test/jev-loop.bats                     # the suite that guards all of it
```

`URL=` targets an existing dashboard and starts nothing locally. Without it,
the loop owns its target.

## How the dashboard is isolated

| Dimension | What the loop does |
| :--- | :--- |
| Port | Drawn at random from **41000-44999**, re-drawn until free. `port_is_reserved()` rejects anything privileged plus `8080-8099` (port-forwards), `8200` (OpenBao), `5001` (registry), `18080-18099` (secondary port-forwards), `30754` (the dashboard NodePort on `kind-osramp`). |
| Bind address | `127.0.0.1` only. Never reachable off-box. |
| Mode | `auto` → `vite` if `node_modules/.bin/vite` exists, else `static`. Force with `--dashboard-mode`. |
| Backend | None needed. `VITE_SL_ENV=demo` is the dashboard's **existing** env flag (`src/api/demoMode.ts`); it defaults the runtime demo toggle ON so the api client short-circuits to local fixtures. **No dashboard source was changed for this work.** |
| Scratch | `reports/jev/<run-id>/tmp/`, exported as `TMPDIR`, `XDG_CACHE_HOME`, `XDG_CONFIG_HOME`. Nothing in a shared `/tmp` path. |
| Browser profile | `reports/jev/<run-id>/browser-profile/`, exported as `JEV_BROWSER_PROFILE_DIR`. Declared even though today's bot drives no browser, so a future browser oracle inherits the isolation rather than reaching into `~/.config`. |
| Teardown | `trap cleanup EXIT INT TERM`. TERM then KILL to the server's **process group** — `vite` forks, and TERMing only the parent leaves `esbuild` holding the port. Scratch and profile are removed; reports survive. |

Two things are worth knowing before you trust a green run.

**The static mode executes no JavaScript, and neither does the bot.**
`spa-server.py` answers every unknown path with `index.html`, which is what
`vite` and the production `nginx.conf` also do for an SPA route. `bot.py`
fetches over `urllib`. So in static mode the bot sees the same app shell on
every route: it can catch a route the *server* refuses, a 5xx, a hang, a bad
gateway banner or a crash banner in the HTML, and it cannot catch anything
that only happens once React has rendered. `loop_report.py` therefore reports
`"console_errors": []` alongside `"console_errors_observable": false` — the key
is present and the honest caveat travels with it, rather than being omitted and
inviting someone to read "no console errors" into a report that never looked.
Catching render-time defects needs a browser-driven oracle; that is not this.

**Coverage is asserted, not hoped for.** Before anything starts, the loop
compares the route list it is about to walk against a fresh `routes.py`
derivation and exits **4** if the list is short. Without that, a hand-trimmed
list reports 100% of its own narrower definition of "everything".

## The derived surface

`scripts/jev-test-bot/routes.py` parses `<Route path=…>` out of `App.tsx` —
both the `path="/x"` and the `path={'/x'}` forms — and produces **44** concrete
paths from the current table:

```console
$ make test-bot-routes | wc -l
44
```

| Declared shape | Treatment |
| :--- | :--- |
| `/agents` | taken as-is |
| `/agents/:id` | representative value substituted → `/agents/example` |
| `/demos/agentmaxxing/*` | collapsed onto its addressable parent |
| `*` | dropped; it is a fallback, not a page |
| `/login`, `/callback` | excluded — unauthenticated auth handshake, reason recorded in `EXCLUDED_ROUTES` |

Representative values live in `routes.PARAM_VALUES` and are deliberately
obviously-synthetic, so nobody reads a real-looking id as evidence that the
page under it was really exercised. `test_routes.py` asserts against the
**real** `App.tsx` that every static non-auth route survives derivation, so a
new page cannot go silently unexplored, and reports any route parameter that
has no mapped value.

## A run, verbatim

```console
$ scripts/jev-test-bot/loop.sh --mock --iterations 2 --turns 3 --timeout 8 \
    --run-id runbook-evidence
[jev-loop] route surface derived from App.tsx
[jev-loop] 44 route(s) to explore, 2 iteration(s)
[jev-loop] starting the static SPA shell on 127.0.0.1:42243
[jev-loop] dashboard ready after 0ms (pid 3937185, pgid 3937185)
[jev-loop] ── iteration 1/2 ──
iteration 1: 44/44 routes visited, 0 bug(s), 0 unvisited
[jev-loop] ── iteration 2/2 ──
iteration 2: 44/44 routes visited, 0 bug(s), 0 unvisited
summary: 2 iteration(s), 44/44 routes covered across the run, 0 bug(s)
[jev-loop] reports under .../reports/jev/runbook-evidence
[jev-loop] PASS — no defects across 2 iteration(s)
[jev-loop] stopping dashboard (pgid 3937185)
$ echo $?
0
```

## Reading the reports

`reports/jev/<run-id>/` (gitignored — per-run evidence, never source):

| File | What it holds |
| :--- | :--- |
| `routes.txt` | the exact list walked |
| `dashboard.log` | the server's stdout/stderr, including one line per request |
| `iteration-N.log` | every bot run for that iteration, concatenated |
| `iteration-N-areas/NNN-<slug>.json` | one raw `bot.py` report per route |
| `iteration-N.json` | the aggregate: coverage partition, bugs, classification |
| `summary.json` | across iterations: union coverage, routes never visited, totals |

The fields to read first:

- `routes_visited` / `routes_unvisited` — **every** route appears in exactly one.
  `loop_report.py` exits 4 rather than emit a report that cannot account for a
  route, and `loop.sh` propagates that.
- `path_status` — the **worst** HTTP status seen per path, not the last. A route
  that 500s once and 200s on a later turn is not a healthy route.
- `routes_incidental` — routes the bot wandered onto via a link that were not in
  the list. Not a failure; a route here and not in `routes.txt` means the
  derivation missed something.
- `summary.routes_never_visited` — unvisited in **every** iteration. A route
  missed once and hit later is a flake, not a gap; this is the list to chase.
- `http_errors` / `network_errors` / `crash_errors` — the oracle categories,
  grouped by the question you are asking.

## Exit codes

| Code | Meaning |
| :--- | :--- |
| 0 | pass, no defects |
| 1 | defects recorded — read `summary.json` |
| 2 | usage or setup error |
| 3 | the dashboard would not start (last 20 log lines are printed) |
| 4 | the route list does not cover the derived surface |

A bot run exiting 1 on a single route does **not** stop the walk: that is a
finding, not a reason to leave the rest of the surface unexplored. The status
is recorded and the loop continues.

## Running it in a loop alongside other suites

That is the design point, and the port policy plus the per-run report root is
the whole of the mechanism. Two cautions:

- **Pass `MOCK=true` unless you mean to spend TypeSafe quota.** Without a key
  the bot falls back to its simulator anyway, but a key in the environment
  means 44 routes × N iterations × turns of live API calls.
- **`--dashboard-mode vite` needs `node_modules`, which needs the network.**
  `auto` silently prefers `static` when the dependency tree is absent, which is
  the condition `bats test/jev-loop.bats` runs under.

## Tests

| Suite | Covers |
| :--- | :--- |
| `scripts/jev-test-bot/test_routes.py` | derivation, against the real `App.tsx` (11 tests) |
| `scripts/jev-test-bot/test_bot_coverage.py` | route normalisation and the run loop's recording of it (8 tests) |
| `test/jev-loop.bats` | the loop: coverage accounting, teardown, the port policy, the aggregator's gap/defect/unreadable paths (12 tests) |

```bash
python3 -m pytest scripts/jev-test-bot/test_routes.py scripts/jev-test-bot/test_bot_coverage.py -q
bats test/jev-loop.bats
```

All three run offline with no `node_modules` and no TypeSafe key, and have zero
skips — a `skip` on a missing binary would turn a broken build into a silent
pass, which is the failure this whole loop exists to avoid.

## Known gaps

- **No render-time oracle.** As above: no JS execution, so no console errors, no
  React error-boundary detection beyond the "something went wrong" text scan,
  no interaction. `snapshot.js` in the same directory is the in-page action-space
  extractor for a future browser harness and is currently unused by `bot.py`.
- **Static mode cannot distinguish routes.** Every path returns the same shell,
  so "44/44 visited" in static mode means 44 routes were *fetched*, not that 44
  distinct pages rendered. Use `--dashboard-mode vite` with a browser oracle
  when that distinction matters.
- **No API proxy in static mode.** `/api/`, `/afm/` and `/fleet-api/` paths get
  the shell rather than a backend. `--deep` (the backend API sweep) is therefore
  only meaningful against a real deployment via `URL=`.
