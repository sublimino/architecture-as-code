# SLAAT-P2-PRE: Build and test toolchain checklist

Ran via `scripts/slaat-preflight.sh` (proof: `docs/slaat/p2-pre/preflight-env.json`)
plus targeted dry-run compiles per remediation stream.

| Component | Check | Result |
| :--- | :--- | :--- |
| Go | `env GOCACHE=/tmp/... CGO_ENABLED=0 go version` | pass — `go1.26.2 linux/amd64` |
| Go | `go build ./...` in `d2-signalloom/apps/signalloom-stun-sentinel` | pass, exit 0 |
| Python | `python3 -c 'import pytest, pydantic, httpx'` | pass |
| Python | `python3 -m compileall d2-signalloom/apps/fe-signalloom/src` | **fails without cache redirect** (`PermissionError` writing `__pycache__` inside the worktree); **passes** once `PYTHONPYCACHEPREFIX=/tmp/slaat-pycache` is exported |
| Python | `uv run ... pytest tests/test_token_adversarial_verification.py` | pass, 36/36 |
| Python | `uv run ... pytest tests/test_adversarial_api_security.py tests/test_tenant_authorization_matrix.py` | **fail at collection** — `ImportError: cannot import name '_IncludedRouter' from 'fastapi.routing'` (pinned `fastapi==0.115.6` does not export this private symbol); pre-existing, see dependency map |
| Bun/TypeScript | `bun --version` | pass — `1.4.0` |
| Bun/TypeScript | `bun run build` in `d2-signalloom/apps/dashboard-signalloom` | **fail**, exit 2, ~24 pre-existing `tsc` errors in `bridge.test.ts` / `AgentsPage.tsx`; pre-dates SLAAT, out of this card's merge boundary |
| Cluster | `kubectl` context `kind-osramp`, 1/1 node Ready | pass |
| Cluster | `inf-signalloom/postgresql` 1/1, `registry/zot` 1/1 | pass |
| Git | integration ref resolvable, Phase 1 merges present | pass (see errata for the one-commit base-drift note) |

## Cache-directory contract for Phase 2 cards

Every Phase 2 card that builds or tests must redirect all of the following off
the worktree, matching the prior-errata requirement ("Build caches must be
redirected to `/tmp` to prevent nono sandbox permission errors") plus the
Python addition discovered by this card:

```
GOCACHE=/tmp/<slug>-gocache
GOMODCACHE=/tmp/<slug>-gomodcache
GOPATH=/tmp/<slug>-gopath
UV_CACHE_DIR=/tmp/<slug>-uv-cache
UV_CONFIG_FILE=/dev/null
PYTHONPYCACHEPREFIX=/tmp/<slug>-pycache
CGO_ENABLED=0
```
