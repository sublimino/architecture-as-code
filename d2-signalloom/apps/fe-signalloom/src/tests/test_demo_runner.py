"""Exercise the demo-runner API against a real subprocess without cluster access.

These tests exist because the new API deliberately launches a shell script that
mutates a shared cluster. The threat model is that hostile clients will try to
smuggle arbitrary commands through the step parameter, wedge a long-running
process, or leave global state stuck between runs. A fake executable script lets
the suite prove the allowlist, argv handling, cancellation path, and log
polling without touching kubectl.
"""
from __future__ import annotations

import os
import time
from pathlib import Path
from types import SimpleNamespace
from typing import Any, cast
from uuid import uuid4

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
import demo_runner
from api_compat import APIError, settings
from db.connection import set_pool_for_testing
from main import app

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
SUPERADMIN_SUBJECT = "demo-runner"
NON_SUPERADMIN_SUBJECT = "tenant-reader"
EMAIL_SUPERADMIN_SUBJECT = "email-admin"
SUPERADMIN_EMAIL = "demo-user@signalloom.local"
SUBJECT_TENANTS = {
    SUPERADMIN_SUBJECT: "tenant-demo-runner",
    NON_SUPERADMIN_SUBJECT: "tenant-demo-runner",
    EMAIL_SUPERADMIN_SUBJECT: "tenant-demo-runner",
}


class _ReadyPool:
    async def close(self) -> None:
        pass


class _TestJWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        header = jwt.get_unverified_header(token)
        if header.get("kid") != "test-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


def _token_for(subject: str, *, email: str | None = None) -> str:
    now = int(time.time())
    claims: dict[str, Any] = {
        "iss": "https://issuer.test/dex",
        "aud": "signalloom-api",
        "iat": now,
        "nbf": now,
        "exp": now + 300,
        "azp": "signalloom-dashboard",
        "sub": subject,
    }
    if email is not None:
        claims["email"] = email
    return jwt.encode(
        claims,
        TEST_SIGNING_KEY,
        algorithm="RS256",
        headers={"kid": "test-key", "typ": "JWT"},
    )


def _bearer(subject: str, *, email: str | None = None) -> dict[str, str]:
    return {"Authorization": f"Bearer {_token_for(subject, email=email)}"}


def _write_fake_script(script_path: Path) -> None:
    script_path.write_text(
        "#!/usr/bin/env bash\n"
        "echo \"fake-step:$1\"\n"
        "if [ \"$1\" = \"2\" ]; then sleep 30; fi\n"
        "echo \"done:$1\"\n",
        encoding="utf-8",
    )
    script_path.chmod(0o755)


def _wait_for_terminal_run(client: TestClient, run_id: str) -> dict[str, Any]:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        response = client.get(f"/api/demo/supercred/runs/{run_id}", headers=_bearer(SUPERADMIN_SUBJECT))
        payload = response.json()
        if payload["status"] != "running":
            return cast(dict[str, Any], payload)
        time.sleep(0.05)
    raise AssertionError(f"run {run_id} did not finish before deadline")


def _wait_for_running_run(client: TestClient, run_id: str) -> dict[str, Any]:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        response = client.get(f"/api/demo/supercred/runs/{run_id}", headers=_bearer(SUPERADMIN_SUBJECT))
        payload = response.json()
        if payload["status"] == "running":
            return cast(dict[str, Any], payload)
        time.sleep(0.05)
    raise AssertionError(f"run {run_id} never reached running state")


@pytest.fixture(autouse=True)
def reset_demo_runner_state() -> None:
    demo_runner.reset_state_for_testing()
    yield
    demo_runner.reset_state_for_testing()


@pytest.fixture
def client(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> TestClient:
    script_path = tmp_path / "fake-supercred-demo.sh"
    _write_fake_script(script_path)

    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", dict(SUBJECT_TENANTS))
    monkeypatch.setattr(settings, "api_superadmin_subjects", {SUPERADMIN_SUBJECT})
    monkeypatch.setattr(settings, "api_superadmin_emails", {SUPERADMIN_EMAIL})
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())
    monkeypatch.setenv("SUPERCRED_DEMO_SCRIPT", str(script_path))
    monkeypatch.setenv("SUPERCRED_DEMO_CWD", str(tmp_path))
    set_pool_for_testing(_ReadyPool())
    try:
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        set_pool_for_testing(None)


def test_start_requires_authentication(client: TestClient) -> None:
    response = client.post("/api/demo/supercred/runs", json={"step": "1"})
    assert response.status_code == 401


def test_unknown_subject_is_forbidden(client: TestClient) -> None:
    response = client.post("/api/demo/supercred/runs", json={"step": "1"}, headers=_bearer("unknown-subject"))
    assert response.status_code == 403


def test_steps_endpoint_lists_exactly_five_steps(client: TestClient) -> None:
    response = client.get("/api/demo/supercred/steps", headers=_bearer("demo-runner"))
    assert response.status_code == 200
    assert {item["step_id"] for item in response.json()["steps"]} == {"1", "2", "3", "4", "5"}


def test_step_runs_and_reports_success(client: TestClient) -> None:
    start_response = client.post("/api/demo/supercred/runs", json={"step": "1"}, headers=_bearer("demo-runner"))
    assert start_response.status_code == 202
    started = start_response.json()
    assert started["status"] == "running"

    finished = _wait_for_terminal_run(client, started["run_id"])
    assert finished["status"] == "succeeded"
    assert finished["exit_code"] == 0

    log_response = client.get(f"/api/demo/supercred/runs/{started['run_id']}/log", headers=_bearer("demo-runner"))
    log_payload = log_response.json()
    assert "fake-step:1" in log_payload["chunk"]
    assert "done:1" in log_payload["chunk"]


def test_unknown_step_id_is_rejected(client: TestClient) -> None:
    response = client.post("/api/demo/supercred/runs", json={"step": "9"}, headers=_bearer("demo-runner"))
    assert response.status_code == 422
    assert len(demo_runner._runs) == 0


@pytest.mark.parametrize(
    "step_template",
    [
        "1; touch {canary}",
        "1 && touch {canary}",
        "1 | touch {canary}",
        "$(touch {canary})",
        "`touch {canary}`",
        "../../../bin/sh",
        "1\n2",
        "1 5",
        "",
    ],
)
def test_injection_attempts_are_rejected(client: TestClient, tmp_path: Path, step_template: str) -> None:
    canary_path = tmp_path / "pwned"
    step = step_template.format(canary=canary_path)
    response = client.post(
        "/api/demo/supercred/runs",
        json={"step": step},
        headers=_bearer("demo-runner"),
    )
    assert 400 <= response.status_code < 500
    assert not canary_path.exists()
    assert len(demo_runner._runs) == 0


def test_concurrent_start_is_refused(client: TestClient) -> None:
    first_response = client.post("/api/demo/supercred/runs", json={"step": "2"}, headers=_bearer("demo-runner"))
    assert first_response.status_code == 202
    first_run_id = first_response.json()["run_id"]

    second_response = client.post("/api/demo/supercred/runs", json={"step": "1"}, headers=_bearer("demo-runner"))
    assert second_response.status_code == 409
    assert second_response.json()["error"]["code"] == "demo_run_in_progress"
    assert first_run_id in second_response.json()["error"]["message"]

    running = client.get(f"/api/demo/supercred/runs/{first_run_id}", headers=_bearer(SUPERADMIN_SUBJECT))
    assert running.json()["status"] == "running"


def test_reset_midway_cancels_running_step(client: TestClient) -> None:
    first_response = client.post("/api/demo/supercred/runs", json={"step": "2"}, headers=_bearer("demo-runner"))
    assert first_response.status_code == 202
    first_run_id = first_response.json()["run_id"]
    _wait_for_running_run(client, first_run_id)

    with demo_runner._STATE_LOCK:
        first_run = demo_runner._runs[first_run_id]
        assert first_run._process is not None
        pid = first_run._process.pid

    reset_response = client.post("/api/demo/supercred/reset", headers=_bearer(SUPERADMIN_SUBJECT))
    assert reset_response.status_code == 202
    reset_run_id = reset_response.json()["run_id"]

    cancelled = _wait_for_terminal_run(client, first_run_id)
    assert cancelled["status"] == "cancelled"
    with pytest.raises(ProcessLookupError):
        os.kill(pid, 0)

    reset_finished = _wait_for_terminal_run(client, reset_run_id)
    assert reset_finished["status"] == "succeeded"
    assert reset_finished["step_id"] == "5"

    follow_up = client.post("/api/demo/supercred/runs", json={"step": "1"}, headers=_bearer(SUPERADMIN_SUBJECT))
    assert follow_up.status_code == 202
    _wait_for_terminal_run(client, follow_up.json()["run_id"])


def test_run_exceeding_timeout_is_killed(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    """Step 2's fake script sleeps 30s while holding stdout open; a 1s bound must still fire."""
    monkeypatch.setenv("SUPERCRED_DEMO_TIMEOUT_SECONDS", "1")
    start_response = client.post("/api/demo/supercred/runs", json={"step": "2"}, headers=_bearer("demo-runner"))
    assert start_response.status_code == 202
    finished = _wait_for_terminal_run(client, start_response.json()["run_id"])
    assert finished["status"] == "timed_out"
    assert "Timed out" in (finished["error"] or "")


def test_reset_from_clean_state_runs_teardown(client: TestClient) -> None:
    response = client.post("/api/demo/supercred/reset", headers=_bearer("demo-runner"))
    assert response.status_code == 202
    finished = _wait_for_terminal_run(client, response.json()["run_id"])
    assert finished["status"] == "succeeded"
    assert finished["step_id"] == "5"


def test_log_offset_paging_returns_disjoint_chunks(client: TestClient) -> None:
    start_response = client.post("/api/demo/supercred/runs", json={"step": "1"}, headers=_bearer("demo-runner"))
    run_id = start_response.json()["run_id"]
    finished = _wait_for_terminal_run(client, run_id)
    assert finished["status"] == "succeeded"

    first_log = client.get(f"/api/demo/supercred/runs/{run_id}/log", headers=_bearer("demo-runner"))
    first_payload = first_log.json()
    second_log = client.get(
        f"/api/demo/supercred/runs/{run_id}/log",
        headers=_bearer("demo-runner"),
        params={"offset": first_payload["next_offset"]},
    )
    second_payload = second_log.json()

    assert first_payload["chunk"] not in second_payload["chunk"]
    combined = first_payload["chunk"] + second_payload["chunk"]
    whole_log = client.get(f"/api/demo/supercred/runs/{run_id}/log", headers=_bearer(SUPERADMIN_SUBJECT)).json()
    assert combined == whole_log["chunk"]
    assert second_payload["eof"] is True


def test_log_negative_offset_is_rejected(client: TestClient) -> None:
    response = client.get(
        f"/api/demo/supercred/runs/{uuid4().hex}/log",
        headers=_bearer("demo-runner"),
        params={"offset": -1},
    )
    assert response.status_code == 422


def test_run_not_found(client: TestClient) -> None:
    response = client.get(f"/api/demo/supercred/runs/{uuid4().hex}", headers=_bearer(SUPERADMIN_SUBJECT))
    assert response.status_code == 404


def test_missing_script_returns_503(client: TestClient, monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    missing_path = tmp_path / "missing-supercred-demo.sh"
    monkeypatch.setenv("SUPERCRED_DEMO_SCRIPT", str(missing_path))
    response = client.post("/api/demo/supercred/runs", json={"step": "1"}, headers=_bearer("demo-runner"))
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "demo_script_unavailable"


def test_argv_is_a_constant_array_not_a_shell_string(client: TestClient) -> None:
    expected_script = str(Path(os.environ["SUPERCRED_DEMO_SCRIPT"]))
    assert demo_runner._argv_for("3") == [expected_script, "3"]
    assert len(demo_runner._argv_for("3")) == 2
    with pytest.raises(APIError):
        demo_runner._argv_for(cast(str, "9"))


def test_non_superadmin_cannot_start_demo_run(client: TestClient) -> None:
    response = client.post("/api/demo/supercred/runs", json={"step": "1"}, headers=_bearer(NON_SUPERADMIN_SUBJECT))
    assert response.status_code == 403
    assert response.json() == {
        "error": {
            "code": "superadmin_required",
            "message": "Superadmin access is required",
        }
    }


def test_rejected_run_starts_no_process(client: TestClient) -> None:
    """403 is the visible half; the load-bearing half is that nothing ran.

    A status code proves the response, not the side effect. If the gate were
    ever moved BELOW the spawn — or if a future refactor started the
    subprocess and then authorized — the caller would still see 403 while the
    demo script had already begun mutating the cluster. So this asserts the
    runner's own state: no active run, and no run recorded at all.
    """
    response = client.post("/api/demo/supercred/runs", json={"step": "1"}, headers=_bearer(NON_SUPERADMIN_SUBJECT))
    assert response.status_code == 403

    # Read the module state directly rather than through /status, which is
    # itself superadmin-gated — this must not depend on the thing it verifies.
    assert demo_runner._active is None
    assert demo_runner._runs == {}

    # And the superadmin's own view agrees: nothing to show.
    status = client.get("/api/demo/supercred/status", headers=_bearer(SUPERADMIN_SUBJECT))
    assert status.status_code == 200
    assert status.json()["active"] is None
    assert status.json()["recent"] == []


def test_non_superadmin_cannot_reset_demo(client: TestClient) -> None:
    response = client.post("/api/demo/supercred/reset", headers=_bearer(NON_SUPERADMIN_SUBJECT))
    assert response.status_code == 403
    assert response.json() == {
        "error": {
            "code": "superadmin_required",
            "message": "Superadmin access is required",
        }
    }


def test_non_superadmin_reads_phase_state_but_not_the_console(client: TestClient) -> None:
    """The read routes are split by audience, not opened wholesale.

    This test previously asserted 200 on all four reads. Two of them are the
    instructor console rather than demo evidence and are now superadmin-only:

      * /status carries `recent` — the run history of a cluster-mutating
        control plane (which privileged phase ran, when, and whether it
        failed).
      * /runs/{id}/log carries the demo script's raw stdout/stderr.

    Both match the design constraint recorded in the ISA: "run/reset controls
    and raw step logs are superadmin-only; all demo EVIDENCE is visible to any
    authenticated user". The evidence lives on /agents and /compliance, which
    is the point of the second demo window — it is not, and never was, in
    these two payloads.

    /steps (a static phase list) and /runs/{id} (one phase's status) stay open
    so a non-superadmin still sees phase status and the "Show this on ->"
    links, which the page requires.
    """
    start_response = client.post("/api/demo/supercred/runs", json={"step": "1"}, headers=_bearer(SUPERADMIN_SUBJECT))
    run_id = start_response.json()["run_id"]
    _wait_for_terminal_run(client, run_id)

    steps_response = client.get("/api/demo/supercred/steps", headers=_bearer(NON_SUPERADMIN_SUBJECT))
    status_response = client.get("/api/demo/supercred/status", headers=_bearer(NON_SUPERADMIN_SUBJECT))
    run_response = client.get(f"/api/demo/supercred/runs/{run_id}", headers=_bearer(NON_SUPERADMIN_SUBJECT))
    log_response = client.get(f"/api/demo/supercred/runs/{run_id}/log", headers=_bearer(NON_SUPERADMIN_SUBJECT))

    assert steps_response.status_code == 200
    assert run_response.status_code == 200
    assert status_response.status_code == 403
    assert status_response.json()["error"]["code"] == "superadmin_required"
    assert log_response.status_code == 403
    assert log_response.json()["error"]["code"] == "superadmin_required"


def test_superadmin_reads_status_and_log(client: TestClient) -> None:
    """The other half of the split: tightening the gate must not close it on
    the identity the instructor panel actually uses."""
    start_response = client.post("/api/demo/supercred/runs", json={"step": "1"}, headers=_bearer(SUPERADMIN_SUBJECT))
    run_id = start_response.json()["run_id"]
    _wait_for_terminal_run(client, run_id)

    status_response = client.get("/api/demo/supercred/status", headers=_bearer(SUPERADMIN_SUBJECT))
    log_response = client.get(f"/api/demo/supercred/runs/{run_id}/log", headers=_bearer(SUPERADMIN_SUBJECT))

    assert status_response.status_code == 200
    assert status_response.json()["script_available"] is True
    assert log_response.status_code == 200


def test_status_and_log_require_authentication_before_authorization(client: TestClient) -> None:
    """An unauthenticated caller gets 401, not the 403 that would leak the
    existence of an authorization boundary to an anonymous prober."""
    status_response = client.get("/api/demo/supercred/status")
    log_response = client.get("/api/demo/supercred/runs/does-not-exist/log")

    assert status_response.status_code == 401
    assert log_response.status_code == 401


def test_mutating_routes_still_require_authentication_before_authorization(client: TestClient) -> None:
    start_response = client.post("/api/demo/supercred/runs", json={"step": "1"})
    reset_response = client.post("/api/demo/supercred/reset")

    assert start_response.status_code == 401
    assert reset_response.status_code == 401


def test_email_only_superadmin_can_start_demo_run(client: TestClient) -> None:
    start_response = client.post(
        "/api/demo/supercred/runs",
        json={"step": "1"},
        headers=_bearer(EMAIL_SUPERADMIN_SUBJECT, email=SUPERADMIN_EMAIL.upper()),
    )
    assert start_response.status_code == 202

    finished = _wait_for_terminal_run(client, start_response.json()["run_id"])
    assert finished["status"] == "succeeded"
