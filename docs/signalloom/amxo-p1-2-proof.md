# AMXO-P1-2 execution proof

- **Generated:** 2026-09-12
- **Base HEAD:** `ebd90f096bfc43bda100463f284941ffaa8caa19`
- **Worktree:** `/home/andy/src/.worktrees/2e369/osramp-demo`
- **Shell PWD alias:** `/home/andy/.cline/worktrees/2e369/osramp-demo`

## Worktree and kernel gates

```text
$ git merge-base --is-ancestor integration/agentmaxxing-onboarding-v0.1.0 HEAD
exit 0

$ landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION)
machine=x86_64 kernel=7.1.3+deb13-amd64 landlock_abi=9 errno=0
```

The isolated checkout derives from the required integration branch. The
running Linux kernel exposes Landlock, so the card's declared kernel blocker
does not apply.

## Test proof

```text
$ pytest d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py -k test_privacy_boundaries
collected 15 items / 14 deselected / 1 selected
1 passed, 14 deselected, 1 warning in 0.49s
exit 0
```

The warning is the pre-existing Starlette `httpx` deprecation warning.

```text
$ pytest d2-signalloom/apps/fe-signalloom/src/tests/test_agentmaxxing_host_policy.py d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py -q
..................................... [100%]
37 passed, 1 warning in 0.69s
exit 0
```

```text
$ UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 \
    --with pytest --with pytest-asyncio --with pytest-xdist \
    --with-requirements d2-signalloom/apps/fe-signalloom/src/requirements.txt \
    env PYTHONPATH=d2-signalloom/apps/fe-signalloom/src \
    python3 -m unittest discover \
    -s d2-signalloom/apps/fe-signalloom/src/tests -p 'test_*.py'
......................
Ran 22 tests in 0.003s
OK
exit 0
```

The canonical `uv` wrapper supplies the repository-pinned Python 3.12 and
test-only dependencies while preserving the required unittest discovery
command as the executed inner command. The default host Python 3.14 attempt was
not accepted as evidence because it lacked `pytest_asyncio` and the required
source-path environment.

```text
$ make demo-agentmaxxing-contract-test || true
make: *** No rule to make target 'demo-agentmaxxing-contract-test'. Stop.
shell exit 0 (explicitly tolerated by required command)
```

The reviewed proposal assigns creation of future acceptance targets to later
cards. P1-2 therefore records this probe without editing the shared Makefile.

```text
$ python3 -m py_compile <P1-2 Python files>
$ python3 -m json.tool <each P1-2 JSON schema and fixture>
syntax checks: PASS

$ UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 \
    --with jsonschema==4.23.0 \
    --with-requirements d2-signalloom/apps/fe-signalloom/src/requirements.txt \
    python d2-signalloom/governance/verify_agentmaxxing_contract.py
draft-2020-12 schemas: PASS
canonical policy instance: PASS
allowlisted export instance: PASS
added-root/extra-field/partial-attributes negatives: PASS

$ git diff --cached --check
exit 0
```

## Artifact SHA-256 manifest

```text
1b38de8cfc00083698b55ab379c6343181fd178b7e1e7016e6702f0c0fd9f565  d2-signalloom/apps/fe-signalloom/src/agentmaxxing_host_policy.py
eb8929be4fe09412136affc6295870853e56e6dbdd41dde71fbd05a36753054a  d2-signalloom/apps/fe-signalloom/src/tests/test_agentmaxxing_host_policy.py
8b0ab3c38a39884521922ffb61fe370cd5fad21b43de93906a3578dbf0f194b7  d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py
6435bae4e0fafbfbe84241fd06aadfb6fe022b1cd67f4aaf608e148701b4c43a  d2-signalloom/governance/fixtures/agentmaxxing-host-policy.v1.json
072934471d9d10b722a1ce4d5f01e3ef33e9b152c253273ada4c043f8354d0d6  d2-signalloom/governance/fixtures/agentmaxxing-raw-telemetry.v1.json
b6a11874ab483e91f24be903106aa37fb5da69270b9b12cc456ca676428ee771  d2-signalloom/governance/schemas/agentmaxxing-host-policy.v1.json
6e59bf8efa7f91442cbc1fcc814c0a062ab888fbc0e9546257b613a693f6fd9e  d2-signalloom/governance/schemas/agentmaxxing-export.v1.json
3edf602ad633c9260baca55c01db2303f31a8c522015f8725754dfdd23cc861f  d2-signalloom/governance/verify_agentmaxxing_contract.py
95c4959339581b3fef0156af0c7b3f1bf527333128907dccc897fe5a4d859a3f  docs/signalloom/agentmaxxing-host-policy.md
```

## Negative-boundary proof

The malicious fixture supplies unique canaries for request-selected identity,
raw nono records, commands, paths, URLs, errors, file contents, memory contents,
stream digests, streamed contents, network contents, and nested payload fields.
The focused test asserts that no canary survives serialization. It also proves
that server-supplied tenant-agent-host identity replaces request values and
that integrity verification does not convert absent evidence from `unobserved`.
Additional negatives reject a caller-added root, caller-added destination,
unregistered identity, digest from a non-hashable root, invalid timestamp, and
an observed collection-limit record. The filter is not yet wired into the HTTP
ingestion route; this proof establishes the P1-2 contract rather than P5-3
integration.

No production deployment, external partner call, merge, rebase, push, pull
request, Kanban mutation, migration, or shared composition-root edit occurred.
