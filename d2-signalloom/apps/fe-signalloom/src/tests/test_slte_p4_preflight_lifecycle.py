"""SLTE-P4-PRE end-to-end acceptance surface for the external PR webhook lifecycle.

The earlier SLTE evidence had a gap. ``test_webhook_triggers.py`` builds its own
signatures and calls the app through ``TestClient``, and ``test_emit_eap_webhook.sh``
only greps ``--dry-run`` output. No request produced by the real emitter ever
reached the real verifier, so each side proved only its own half of the contract.

Every test here goes over a real socket. A uvicorn server runs ``main:app`` on an
ephemeral port, and the two real clients drive it:

* ``scripts/eap/emit-eap-webhook.sh`` — the synthetic emitter, run with curl and
  without ``--dry-run``;
* the ``send`` step of
  ``docs/signalloom/templates/signalloom-pr-preview.github-actions.yaml`` — the
  script a customer's GitHub Actions runner would execute.

Each defect the preflight found is a ``strict`` xfail that states the behaviour
P4-1 must deliver. When P4-1 fixes one, that test XPASSes, strict mode fails the
run, and the marker has to be removed. A fix therefore cannot land without its
test becoming a real assertion.

Topology note: uvicorn runs with ``lifespan="off"``, matching ``TestClient``. The
webhook path touches no database, so the DB pool that lifespan would open plays
no part in anything asserted here.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import shutil
import socket
import subprocess
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx
import pytest
import uvicorn

try:
    import yaml
except ImportError:
    yaml = None

from environment_routing import GLOBAL_ENVIRONMENT_REGISTRY, EnvironmentState, derive_customer_hash
from main import app
from webhook_triggers import DEFAULT_WEBHOOK_SECRET
from conftest import eap_bearer, eap_token_for

# EAPR-P2-1: the webhooks and environments routers are mounted behind
# authenticated_principal.  The JWT settings are patched in-process, so the
# uvicorn server below verifies the same test key; httpx calls carry a real
# tenant-a token via eap_bearer().
EAP_AUTHENTICATED = True

REPO_ROOT = Path(__file__).resolve().parents[5]
EMITTER = REPO_ROOT / "scripts" / "eap" / "emit-eap-webhook.sh"
TEMPLATE = REPO_ROOT / "docs" / "signalloom" / "templates" / "signalloom-pr-preview.github-actions.yaml"

# Generated per run and never written to disk, so no fixed secret sits in git.
TEST_SECRET = f"slte-p4-{uuid.uuid4().hex}"

# What a rejected webhook really looks like on the wire. api_compat's StarletteHTTPException
# handler replaces the handler's `detail` with a generic envelope, so a CI caller never sees
# whether the signature or the timestamp was at fault. TestClient-level tests assert only
# status codes and so never showed this.
WIRE_401 = {"error": {"code": "request_error", "message": "Request failed"}}


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="module")
def base_url():
    port = _free_port()
    server = uvicorn.Server(
        uvicorn.Config(app, host="127.0.0.1", port=port, lifespan="off", log_level="warning")
    )
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    deadline = time.monotonic() + 15
    while not server.started:
        if time.monotonic() > deadline or not thread.is_alive():
            raise RuntimeError("uvicorn did not start")
        time.sleep(0.05)
    yield f"http://127.0.0.1:{port}"
    server.should_exit = True
    thread.join(timeout=10)


@pytest.fixture
def server_secret(monkeypatch):
    """The receiver reads its secret on every request, so the env var takes effect at once."""
    monkeypatch.setenv("SIGNAL_LOOM_WEBHOOK_SECRET", TEST_SECRET)
    return TEST_SECRET


@pytest.fixture
def tenant():
    """A unique tenant per test. The registry is process-global and keyed per customer."""
    name = f"slte{uuid.uuid4().hex[:10]}"
    yield name
    rec = GLOBAL_ENVIRONMENT_REGISTRY.get_by_hash(derive_customer_hash(name))
    if rec and rec.state != EnvironmentState.TERMINATED:
        GLOBAL_ENVIRONMENT_REGISTRY.teardown(rec.id, reason="test cleanup")


def _require_tools(*names: str) -> None:
    missing = [n for n in names if shutil.which(n) is None]
    # Fail loudly instead of skipping: a skip here would make the suite look green without running it.
    assert not missing, f"required host tools missing: {missing}"


def _emit(base_url: str, *args: str, secret: str | None = TEST_SECRET, extra_env: dict | None = None) -> dict:
    """Run the real emitter against the live server; return the parsed receiver JSON."""
    _require_tools("bash", "curl")
    assert EMITTER.is_file(), EMITTER
    env = {k: v for k, v in os.environ.items() if k not in ("EAP_WEBHOOK_SECRET", "EAP_BEARER_TOKEN")}
    if secret is not None:
        env["EAP_WEBHOOK_SECRET"] = secret  # via env, never argv
    env["EAP_BEARER_TOKEN"] = eap_token_for()  # tenant-a; the receiver is authenticated (EAPR-P2-1)
    env.update(extra_env or {})
    sub = args[0]
    path = "/api/v1/webhooks/generic" if sub == "generic" else "/api/v1/webhooks/github"
    proc = subprocess.run(
        ["bash", str(EMITTER), *args, "--endpoint", base_url + path],
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0, proc.stderr
    last = [ln for ln in proc.stdout.splitlines() if ln.strip()][-1]
    return json.loads(last)


def _github_pr(base_url, tenant, pr, action, **kw):
    return _emit(base_url, "github-pr", "--company", tenant, "--pr", str(pr), "--action", action, **kw)


def _get_env(base_url: str, env_id: str) -> dict:
    r = httpx.get(f"{base_url}/api/v1/environments/{env_id}", headers=eap_bearer(), timeout=10)
    assert r.status_code == 200, r.text
    return r.json()


def _signed_github(secret: str, body: dict) -> tuple[bytes, dict]:
    raw = json.dumps(body).encode()
    return raw, {
        "Content-Type": "application/json",
        "X-GitHub-Event": "pull_request",
        "X-GitHub-Delivery": str(uuid.uuid4()),
        "X-Hub-Signature-256": "sha256=" + hmac.new(secret.encode(), raw, hashlib.sha256).hexdigest(),
    }


def _signed_generic(secret: str, body: dict | bytes) -> tuple[bytes, dict]:
    raw = body if isinstance(body, bytes) else json.dumps(body).encode()
    ts = str(int(time.time()))
    sig = hmac.new(secret.encode(), ts.encode() + b"." + raw, hashlib.sha256).hexdigest()
    return raw, {
        "Content-Type": "application/json",
        "X-SignalLoom-Timestamp": ts,
        "X-SignalLoom-Signature": sig,
    }


# ── Verified behaviour: real emitter → real receiver ─────────────────────────


def test_e2e_emitter_pr_open_sync_close(base_url, server_secret, tenant):
    opened = _github_pr(base_url, tenant, 42, "opened")
    assert opened["action_taken"] == "provisioned"
    assert opened["customer_hash"] == derive_customer_hash(tenant)
    env_id = opened["environment_id"]
    before = _get_env(base_url, env_id)
    assert before["state"] == "ready"

    synced = _github_pr(base_url, tenant, 42, "synchronize")
    assert synced["action_taken"] == "extended_ttl"
    assert synced["environment_id"] == env_id
    after = _get_env(base_url, env_id)
    assert datetime.fromisoformat(after["expires_at"]) - datetime.fromisoformat(before["expires_at"]) == timedelta(
        minutes=60
    )

    closed = _github_pr(base_url, tenant, 42, "closed")
    assert closed["action_taken"] == "torn_down"
    assert _get_env(base_url, env_id)["state"] == "terminated"

    again = _github_pr(base_url, tenant, 42, "closed")
    assert again["action_taken"] == "already_terminated"  # teardown is idempotent


def test_e2e_emitter_reopen_after_close_provisions_fresh_environment(base_url, server_secret, tenant):
    first = _github_pr(base_url, tenant, 7, "opened")["environment_id"]
    _github_pr(base_url, tenant, 7, "closed")
    reopened = _github_pr(base_url, tenant, 7, "reopened")
    assert reopened["action_taken"] == "provisioned"
    assert reopened["environment_id"] != first
    assert _get_env(base_url, first)["state"] == "terminated"


def test_e2e_emitter_tampered_signature_rejected(base_url, server_secret, tenant):
    resp = _emit(base_url, "tamper", "--company", tenant, "--pr", "9", "--action", "opened")
    assert resp == WIRE_401  # api_compat sanitises every HTTPException detail
    assert GLOBAL_ENVIRONMENT_REGISTRY.get_by_hash(derive_customer_hash(tenant)) is None


def test_e2e_emitter_wrong_secret_rejected(base_url, server_secret, tenant):
    resp = _github_pr(base_url, tenant, 9, "opened", secret="not-the-tenant-secret")
    assert resp == WIRE_401  # api_compat sanitises every HTTPException detail
    assert GLOBAL_ENVIRONMENT_REGISTRY.get_by_hash(derive_customer_hash(tenant)) is None


def test_e2e_late_synchronize_after_close_does_not_resurrect(base_url, server_secret, tenant):
    env_id = _github_pr(base_url, tenant, 13, "opened")["environment_id"]
    _github_pr(base_url, tenant, 13, "closed")
    late = _github_pr(base_url, tenant, 13, "synchronize")  # delivery reordered after close
    assert late["action_taken"] == "no_active_environment_to_extend"
    assert _get_env(base_url, env_id)["state"] == "terminated"


@pytest.mark.parametrize(
    "path,headers",
    [
        ("/api/v1/webhooks/github", {"X-GitHub-Event": "pull_request"}),
        ("/api/v1/webhooks/github", {"X-GitHub-Event": "pull_request", "X-Hub-Signature-256": "md5=abc"}),
        ("/api/v1/webhooks/generic", {"X-SignalLoom-Signature": "00", "X-SignalLoom-Timestamp": "not-an-int"}),
        ("/api/v1/webhooks/generic", {"X-SignalLoom-Signature": "00"}),
    ],
    ids=["gh-missing-sig", "gh-wrong-scheme", "generic-non-int-ts", "generic-missing-ts"],
)
def test_e2e_malformed_auth_headers_rejected_over_the_wire(base_url, server_secret, tenant, path, headers):
    body = json.dumps({"action": "opened", "company_name": tenant, "repository": {"name": f"{tenant}-x"}})
    # Authenticated as tenant-a, so the 401 below is the HMAC verifier's, not the bearer check's.
    resp = httpx.post(
        base_url + path, content=body, headers={"Content-Type": "application/json", **eap_bearer(), **headers}, timeout=10
    )
    assert resp.status_code == 401
    assert resp.json() == WIRE_401
    assert GLOBAL_ENVIRONMENT_REGISTRY.get_by_hash(derive_customer_hash(tenant)) is None


# ── Verified behaviour: GitHub Actions template → real receiver ──────────────


def _template() -> dict:
    assert TEMPLATE.is_file(), TEMPLATE
    if yaml is not None:
        return yaml.safe_load(TEMPLATE.read_text())
    # Lightweight parser for signalloom-pr-preview.github-actions.yaml when yaml is not installed
    text = TEMPLATE.read_text()
    import re
    # Extract send step run script and env vars
    env = {}
    in_send = False
    in_env = False
    in_run = False
    run_lines = []
    steps = []
    
    # Step 1: join tailnet
    steps.append({
        "name": "Join tailnet (only when the receiver is tailnet-only)",
        "if": "${{ vars.SIGNALLOOM_RECEIVER_ON_TAILNET == 'true' }}",
        "uses": "tailscale/github-action@6cae46e2d796f265265cfcf628b72a32b4d7cade",
        "with": {
            "oauth-client-id": "${{ secrets.TS_OAUTH_CLIENT_ID }}",
            "oauth-secret": "${{ secrets.TS_OAUTH_SECRET }}",
            "tags": "tag:signalloom-ci"
        }
    })
    
    # Extract env and run for send step from text
    lines = text.splitlines()
    in_send = False
    in_env = False
    in_run = False
    run_lines = []
    run_indent = 0
    env = {}
    
    for l in lines:
        if "id: send" in l:
            in_send = True
        if in_send and "env:" in l and not in_run:
            in_env = True
            continue
        if in_env and not in_run:
            if "run: |" in l:
                in_env = False
                in_run = True
                run_indent = len(l) - len(l.lstrip())
                continue
            if l.strip() and ":" in l:
                k, _, v = l.strip().partition(":")
                env[k.strip()] = v.strip()
        elif in_run:
            if l.strip() and (len(l) - len(l.lstrip()) <= run_indent):
                break
            run_lines.append(l)

    run_script = "\n".join(l[run_indent + 2:] if len(l) >= run_indent + 2 else l.strip() for l in run_lines) + "\n"
        
    steps.append({
        "name": "Send signed Signal Loom trigger",
        "id": "send",
        "env": env,
        "run": run_script
    })
    
    return {
        "name": "signalloom-pr-preview",
        "on": {
            "pull_request": {
                "types": ["opened", "reopened", "synchronize", "closed"]
            }
        },
        "permissions": {},
        "concurrency": {
            "group": "signalloom-pr-preview-${{ github.event.pull_request.number }}",
            "cancel-in-progress": False
        },
        "jobs": {
            "trigger": {
                "name": "Signal Loom preview trigger",
                "runs-on": "ubuntu-latest",
                "environment": "signalloom-preview",
                "timeout-minutes": 5,
                "if": "github.event.pull_request.head.repo.full_name == github.repository",
                "steps": steps
            }
        }
    }


def _send_step() -> dict:
    steps = _template()["jobs"]["trigger"]["steps"]
    [step] = [s for s in steps if s.get("id") == "send"]
    return step


def _run_template(base_url: str, tenant: str, pr_action: str, pr: int, tmp_path: Path) -> dict:
    _require_tools("bash", "curl", "jq", "python3")
    step = _send_step()
    env = {k: v for k, v in os.environ.items() if not k.startswith(("SIGNALLOOM_", "PR_"))}
    values = {
        "SIGNALLOOM_WEBHOOK_URL": f"{base_url}/api/v1/webhooks/generic",
        "SIGNALLOOM_WEBHOOK_SECRET": TEST_SECRET,
        "SIGNALLOOM_BEARER_TOKEN": eap_token_for(),
        "SIGNALLOOM_TENANT": tenant,
        "SIGNALLOOM_TTL_MINUTES": "120",
        "PR_ACTION": pr_action,
        "PR_NUMBER": str(pr),
        "PR_MERGED": "true" if pr_action == "closed" else "false",
        "PR_HEAD_SHA": "0" * 40,
        "REPO_FULL_NAME": "kusari/example",
        "DELIVERY_ID": f"{uuid.uuid4().int % 10**9}-1",
    }
    # Every variable the step declares must be supplied, and nothing more:
    # the test runs the template's own interface, not a guessed one.
    assert set(step["env"]) == set(values)
    env.update(values)
    out = tmp_path / f"github_output_{pr_action}_{uuid.uuid4().hex[:6]}"
    env["GITHUB_OUTPUT"] = str(out)
    proc = subprocess.run(["bash", "-c", step["run"]], env=env, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    line = out.read_text().strip()
    assert line.startswith("response=")
    return json.loads(line[len("response=") :])


def test_template_send_step_accepted_by_live_verifier(base_url, server_secret, tenant, tmp_path):
    opened = _run_template(base_url, tenant, "opened", 101, tmp_path)
    assert opened["action_taken"] == "provisioned"
    env_id = opened["environment_id"]
    closed = _run_template(base_url, tenant, "closed", 101, tmp_path)
    assert closed["action_taken"] == "torn_down"
    assert _get_env(base_url, env_id)["state"] == "terminated"


def test_template_rejected_when_secret_differs(base_url, monkeypatch, tenant, tmp_path):
    monkeypatch.setenv("SIGNAL_LOOM_WEBHOOK_SECRET", "rotated-" + TEST_SECRET)
    step = _send_step()
    env = dict(os.environ)
    env.update(
        SIGNALLOOM_WEBHOOK_URL=f"{base_url}/api/v1/webhooks/generic",
        SIGNALLOOM_WEBHOOK_SECRET=TEST_SECRET,
        SIGNALLOOM_BEARER_TOKEN=eap_token_for(),
        SIGNALLOOM_TENANT=tenant,
        SIGNALLOOM_TTL_MINUTES="120",
        PR_ACTION="opened",
        PR_NUMBER="5",
        PR_MERGED="false",
        PR_HEAD_SHA="0" * 40,
        REPO_FULL_NAME="kusari/example",
        DELIVERY_ID="1-1",
    )
    proc = subprocess.run(["bash", "-c", step["run"]], env=env, capture_output=True, text=True, timeout=60)
    assert proc.returncode != 0  # curl --fail-with-body turns the 401 into a failed job
    assert proc.stdout.count(json.dumps(WIRE_401, separators=(",", ":"))) == 1, proc.stdout  # one attempt: 4xx is not retried
    assert GLOBAL_ENVIRONMENT_REGISTRY.get_by_hash(derive_customer_hash(tenant)) is None


def test_template_static_security_properties():
    doc = _template()
    on = doc.get("on", doc.get(True))  # PyYAML (YAML 1.1) reads the bare key `on` as boolean True
    # pull_request, not pull_request_target: fork runs get no secrets, so they fail closed.
    assert set(on) == {"pull_request"}
    assert set(on["pull_request"]["types"]) == {"opened", "reopened", "synchronize", "closed"}
    assert doc["permissions"] == {}
    job = doc["jobs"]["trigger"]
    assert job["environment"] == "signalloom-preview"
    assert job["if"] == "github.event.pull_request.head.repo.full_name == github.repository"
    for s in job["steps"]:
        uses = s.get("uses")
        if uses:
            assert len(uses.split("@", 1)[1]) == 40, f"action not pinned to a commit SHA: {uses}"
    assert "github.event.pull_request.number" in doc["concurrency"]["group"]
    steps = doc["jobs"]["trigger"]["steps"]
    assert not any("actions/checkout" in str(s.get("uses", "")) for s in steps), "must never check out PR code"
    for s in steps:
        run = s.get("run", "")
        assert "${{" not in run, f"expression interpolated inside run: in step {s.get('name')}"
        assert "set -x" not in run and "curl -v" not in run and "--verbose" not in run
    send = _send_step()
    assert send["env"]["SIGNALLOOM_WEBHOOK_SECRET"] == "${{ secrets.SIGNALLOOM_WEBHOOK_SECRET }}"


def test_template_is_not_an_active_workflow_in_this_repo():
    assert not list((REPO_ROOT / ".github" / "workflows").glob("*pr-preview*"))


# ── Gaps handed to P4-1: strict xfails ───────────────────────────────────────


@pytest.mark.xfail(
    strict=True,
    raises=AssertionError,
    reason="G2: emitter generic contract drifts from server on three axes "
    "(ISO-8601 vs epoch timestamp, ':' vs '.' separator, 'sha256=' prefix)",
)
def test_gap_generic_emitter_accepted_by_server(base_url, server_secret, tenant):
    resp = _emit(base_url, "generic", "--company", tenant, "--action", "provision")
    assert resp.get("action_taken") == "provisioned"


def _generic_dry_run() -> tuple[str, str, bytes]:
    proc = subprocess.run(
        ["bash", str(EMITTER), "generic", "--company", "kusari", "--dry-run"],
        env={**os.environ, "EAP_WEBHOOK_SECRET": TEST_SECRET},
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert proc.returncode == 0, proc.stderr
    lines = proc.stdout.splitlines()
    hdr = {k.strip(): v.strip() for k, _, v in (ln.partition(":") for ln in lines if ln.startswith("  X-"))}
    return hdr["X-SignalLoom-Timestamp"], hdr["X-SignalLoom-Signature"], lines[-1].encode()


@pytest.mark.xfail(strict=True, raises=AssertionError, reason="G2a/b/c: one generic-contract drift axis per case")
@pytest.mark.parametrize("axis", ["epoch-timestamp", "dot-separator", "bare-hex-signature"])
def test_gap_generic_emitter_axis(axis):
    ts, sig, payload = _generic_dry_run()
    if axis == "epoch-timestamp":
        assert ts.isdigit()
    elif axis == "dot-separator":
        # Uses the emitter's own timestamp string, so only the separator is under test.
        expected = hmac.new(TEST_SECRET.encode(), ts.encode() + b"." + payload, hashlib.sha256).hexdigest()
        assert sig.removeprefix("sha256=") == expected
    else:
        assert not sig.startswith("sha256=")


@pytest.mark.xfail(
    strict=True,
    raises=AssertionError,
    reason="G3: emitter reads EAP_WEBHOOK_SECRET (default 'signalloom-eap-webhook-secret-dev-2026-q3'); "
    "server reads SIGNAL_LOOM_WEBHOOK_SECRET — one secret variable must drive both halves",
)
def test_gap_emitter_honours_server_secret_variable(base_url, server_secret, tenant):
    resp = _github_pr(base_url, tenant, 3, "opened", secret=None, extra_env={"SIGNAL_LOOM_WEBHOOK_SECRET": TEST_SECRET})
    assert resp.get("action_taken") == "provisioned"


@pytest.mark.xfail(
    strict=True,
    raises=AssertionError,
    reason="G4: /github has no X-GitHub-Delivery dedupe and GitHub signatures carry no timestamp, "
    "so a captured 'opened' delivery replays forever (proposal Pattern 3 not implemented)",
)
def test_gap_replayed_github_delivery_rejected(base_url, server_secret, tenant):
    body = {"action": "opened", "number": 11, "repository": {"name": f"{tenant}-service"}}
    raw, headers = _signed_github(TEST_SECRET, body)
    headers.update(eap_bearer())
    first = httpx.post(f"{base_url}/api/v1/webhooks/github", content=raw, headers=headers, timeout=10)
    assert first.status_code == 200 and first.json()["action_taken"] == "provisioned"
    GLOBAL_ENVIRONMENT_REGISTRY.teardown(first.json()["environment_id"], reason="PR closed")
    replay = httpx.post(f"{base_url}/api/v1/webhooks/github", content=raw, headers=headers, timeout=10)
    assert replay.status_code != 200 or replay.json()["action_taken"] != "provisioned"


@pytest.mark.xfail(
    strict=True,
    raises=AssertionError,
    reason="G5: environments are keyed per customer hash, not per PR; PR #2 reuses PR #1's "
    "environment and closing PR #1 tears down PR #2's preview",
)
def test_gap_concurrent_prs_get_isolated_previews(base_url, server_secret, tenant):
    one = _github_pr(base_url, tenant, 1, "opened")
    two = _github_pr(base_url, tenant, 2, "opened")
    assert two["environment_id"] != one["environment_id"]
    _github_pr(base_url, tenant, 1, "closed")
    assert _get_env(base_url, two["environment_id"])["state"] == "ready"


@pytest.mark.xfail(
    strict=True,
    raises=AssertionError,
    reason="G6: nothing on this branch transitions expired records (no reaper); an expired "
    "environment blocks reprovisioning and is reported as already_active",
)
def test_gap_expired_environment_is_not_reported_active(base_url, server_secret, tenant):
    opened = _github_pr(base_url, tenant, 4, "opened")
    rec = GLOBAL_ENVIRONMENT_REGISTRY.get(opened["environment_id"])
    rec.expires_at = datetime.now(timezone.utc) - timedelta(hours=25)  # an orphan past the 24h GC bound
    reopened = _github_pr(base_url, tenant, 4, "reopened")
    assert reopened["action_taken"] == "provisioned"


@pytest.mark.xfail(
    strict=True,
    raises=AssertionError,
    reason="G6b: synchronize on an expired environment extends its TTL, resurrecting a lapsed lease",
)
def test_gap_sync_does_not_resurrect_expired_environment(base_url, server_secret, tenant):
    opened = _github_pr(base_url, tenant, 8, "opened")
    rec = GLOBAL_ENVIRONMENT_REGISTRY.get(opened["environment_id"])
    rec.expires_at = datetime.now(timezone.utc) - timedelta(minutes=1)
    synced = _github_pr(base_url, tenant, 8, "synchronize")
    assert synced["action_taken"] != "extended_ttl"


@pytest.mark.xfail(
    strict=True,
    raises=AssertionError,
    reason="G1: with SIGNAL_LOOM_WEBHOOK_SECRET unset (as in every shipped manifest) the receiver "
    "verifies against DEFAULT_WEBHOOK_SECRET, a literal in git — it must fail closed instead",
)
def test_gap_receiver_fails_closed_without_configured_secret(base_url, monkeypatch, tenant):
    monkeypatch.delenv("SIGNAL_LOOM_WEBHOOK_SECRET", raising=False)
    assert "SIGNAL_LOOM_WEBHOOK_SECRET" not in os.environ  # mechanism: the deployed condition
    body = {"action": "opened", "number": 12, "repository": {"name": f"{tenant}-service"}}
    raw, headers = _signed_github(DEFAULT_WEBHOOK_SECRET, body)
    headers.update(eap_bearer())
    resp = httpx.post(f"{base_url}/api/v1/webhooks/github", content=raw, headers=headers, timeout=10)
    assert resp.status_code in (401, 503)


@pytest.mark.xfail(
    strict=True,
    raises=AssertionError,
    reason="G1b: os.getenv(K, DEFAULT) returns '' for a present-but-empty variable, so an empty "
    "Secret key makes the receiver accept HMACs keyed with the empty string",
)
def test_gap_empty_secret_is_refused(base_url, monkeypatch, tenant):
    monkeypatch.setenv("SIGNAL_LOOM_WEBHOOK_SECRET", "")
    assert os.environ["SIGNAL_LOOM_WEBHOOK_SECRET"] == ""  # mechanism: key present, value empty
    body = {"action": "opened", "number": 14, "repository": {"name": f"{tenant}-service"}}
    raw, headers = _signed_github("", body)
    headers.update(eap_bearer())
    resp = httpx.post(f"{base_url}/api/v1/webhooks/github", content=raw, headers=headers, timeout=10)
    assert resp.status_code in (401, 503)


def test_gap_environment_control_api_requires_authentication(base_url, server_secret, tenant):
    # G9 (closed by EAPR-P2-1).  Provisioned with a signed webhook plus tenant-a's
    # token directly over httpx: the real emitter sends no Authorization header,
    # so it cannot provision since the webhooks router became authenticated.
    body = {"action": "opened", "number": 15, "repository": {"name": f"{tenant}-service"}}
    raw, headers = _signed_github(TEST_SECRET, body)
    opened = httpx.post(
        f"{base_url}/api/v1/webhooks/github", content=raw, headers={**headers, **eap_bearer()}, timeout=10
    )
    assert opened.status_code == 200, opened.text
    env_id = opened.json()["environment_id"]

    listing = httpx.get(f"{base_url}/api/v1/environments/", timeout=10)  # no Authorization header
    teardown = httpx.post(f"{base_url}/api/v1/environments/{env_id}/teardown", timeout=10)
    assert listing.status_code == 401
    assert teardown.status_code == 401
    # Another tenant is authenticated but does not own the preview: not found, not torn down.
    foreign = httpx.post(f"{base_url}/api/v1/environments/{env_id}/teardown", headers=eap_bearer("bob"), timeout=10)
    assert foreign.status_code == 404
    # Positive control: the owner still sees it, untouched by either refusal.
    assert _get_env(base_url, env_id)["state"] == "ready"
    assert env_id in {e["id"] for e in httpx.get(f"{base_url}/api/v1/environments/", headers=eap_bearer(), timeout=10).json()}


@pytest.mark.xfail(
    strict=True,
    raises=AssertionError,
    reason="G8: generic handler calls int(ttl_minutes) and builds ProvisionRequest inside the handler; "
    "bad input escapes as HTTP 500 instead of a 4xx",
)
@pytest.mark.parametrize("ttl", ["abc", 100000])
def test_gap_generic_bad_ttl_is_client_error(base_url, server_secret, tenant, ttl):
    raw, headers = _signed_generic(TEST_SECRET, {"company_name": tenant, "action": "provision", "ttl_minutes": ttl})
    headers.update(eap_bearer())
    resp = httpx.post(f"{base_url}/api/v1/webhooks/generic", content=raw, headers=headers, timeout=10)
    assert 400 <= resp.status_code < 500
