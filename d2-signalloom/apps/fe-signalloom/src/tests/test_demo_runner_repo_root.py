"""Repo-root resolution under a container (shallow) module layout.

The demo runner derives the repo root by walking up from ``__file__``. In the
source tree the module sits at
``d2-signalloom/apps/fe-signalloom/src/demo_runner.py`` — exactly four levels
below the repo root, so ``parents[4]`` lands on it. The published image
installs the module flat at ``/app/demo_runner.py``, where ``parents`` holds
only ``['/app', '/']`` and that index is out of range.

Every pre-existing demo-runner test misses this for one of two reasons, and
both are properties of the harness rather than of the code under test:

* ``test_demo_runner{,_multidemo,_streaming,_stream_sse,_log_wait}.py`` set
  ``SUPERCRED_DEMO_CWD``/``SIGNALFUSION_DEMO_CWD`` to a ``tmp_path``, so the
  override branch returns before the index is ever evaluated. The defective
  expression does not execute.
* The tests that set no override (``test_demo_runner_main.py``,
  ``test_demo_runner_audit.py``, ``test_tenant_isolation.py``) execute it and
  succeed, because pytest runs them from the source tree where the depth
  assumption holds.

Neither condition holds in the container, which is why a suite that is green
on every run ships an endpoint that answers 500. These tests reproduce the
container layout directly by pointing the module's ``__file__`` at a shallow
path, so they fail against the defect from inside the repo tree.
"""
from __future__ import annotations

import time
from pathlib import Path
from types import SimpleNamespace

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
import demo_runner
from api_compat import APIError, settings
from db.connection import set_pool_for_testing
from main import app

# The layout the image actually ships: module installed flat under /app, whose
# .parents is ['/app', '/'] — two entries against an index of 4.
CONTAINER_MODULE_PATH = "/app/demo_runner.py"

TEST_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
SUPERADMIN_SUBJECT = "demo-runner"

# Both halves of each demo's configuration. The script override short-circuits
# script_path() before the repo root is consulted, so a test that clears only
# the CWD variable still never reaches the defect.
DEMO_ENV_VARS = (
    "SUPERCRED_DEMO_CWD",
    "SUPERCRED_DEMO_SCRIPT",
    "SUPERCRED_EVIDENCE_SCRIPT",
    "SIGNALFUSION_DEMO_CWD",
    "SIGNALFUSION_DEMO_SCRIPT",
)


class _ReadyPool:
    async def close(self) -> None:
        pass


class _TestJWKClient:
    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        header = jwt.get_unverified_header(token)
        if header.get("kid") != "test-key":
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=TEST_SIGNING_KEY.public_key())


def _bearer(subject: str) -> dict[str, str]:
    now = int(time.time())
    token = jwt.encode(
        {
            "iss": "https://issuer.test/dex",
            "aud": "signalloom-api",
            "iat": now,
            "nbf": now,
            "exp": now + 300,
            "azp": "signalloom-dashboard",
            "sub": subject,
        },
        TEST_SIGNING_KEY,
        algorithm="RS256",
        headers={"kid": "test-key", "typ": "JWT"},
    )
    return {"Authorization": f"Bearer {token}"}


def _apply_container_layout(monkeypatch: pytest.MonkeyPatch) -> None:
    """Make the module look installed the way the image installs it."""
    for name in DEMO_ENV_VARS:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(demo_runner, "__file__", CONTAINER_MODULE_PATH)


@pytest.fixture(autouse=True)
def reset_demo_runner_state() -> None:
    demo_runner.reset_state_for_testing()
    yield
    demo_runner.reset_state_for_testing()


@pytest.fixture
def container_client(monkeypatch: pytest.MonkeyPatch) -> TestClient:
    """A client whose demo runner sees the container's shallow module path."""
    monkeypatch.setattr(settings, "api_jwt_issuer", "https://issuer.test/dex")
    monkeypatch.setattr(settings, "api_jwt_audience", "signalloom-api")
    monkeypatch.setattr(settings, "api_jwt_authorized_party", "signalloom-dashboard")
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", {SUPERADMIN_SUBJECT: "tenant-demo-runner"})
    monkeypatch.setattr(settings, "api_superadmin_subjects", {SUPERADMIN_SUBJECT})
    monkeypatch.setattr(settings, "api_superadmin_emails", set())
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _TestJWKClient())
    _apply_container_layout(monkeypatch)
    set_pool_for_testing(_ReadyPool())
    try:
        with TestClient(app, raise_server_exceptions=False) as test_client:
            yield test_client
    finally:
        set_pool_for_testing(None)


# ── The resolver itself ──────────────────────────────────────────────────────


def test_resolve_repo_root_returns_none_under_container_layout(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """An unresolvable root is reported as unknown, not raised as IndexError."""
    _apply_container_layout(monkeypatch)
    assert demo_runner._resolve_repo_root("SIGNALFUSION_DEMO_CWD") is None


@pytest.mark.parametrize(
    "module_path",
    [
        "/demo_runner.py",
        "/app/demo_runner.py",
        "/app/src/demo_runner.py",
        "/opt/a/b/demo_runner.py",
    ],
)
def test_resolve_repo_root_never_raises_for_shallow_paths(
    monkeypatch: pytest.MonkeyPatch, module_path: str
) -> None:
    """Any layout shallower than the source tree resolves to None, not a crash.

    Parametrised over depths because the defect is an off-by-layout index: it
    is silent at depth 5+ and fatal below it, and only the boundary proves the
    guard is on the right side of it.
    """
    for name in DEMO_ENV_VARS:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(demo_runner, "__file__", module_path)
    assert demo_runner._resolve_repo_root("SIGNALFUSION_DEMO_CWD") is None


def test_repo_root_for_raises_actionable_error_under_container_layout(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Callers that must have a root get a 503 that names the missing variable.

    The failure has to be legible to whoever can fix it, so the message is
    asserted to carry the environment variable rather than merely a status.
    """
    _apply_container_layout(monkeypatch)
    with pytest.raises(APIError) as excinfo:
        demo_runner._repo_root_for("SIGNALFUSION_DEMO_CWD")
    assert excinfo.value.status_code == 503
    assert excinfo.value.code == "demo_root_unresolved"
    assert "SIGNALFUSION_DEMO_CWD" in excinfo.value.message


def test_repo_root_legacy_helper_raises_actionable_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The SuperCred helper is covered too — it was the twin of the same bug.

    Two call sites carried this expression. Asserting only the parameterised
    one would have let the SuperCred path keep crashing.
    """
    _apply_container_layout(monkeypatch)
    with pytest.raises(APIError) as excinfo:
        demo_runner._repo_root()
    assert excinfo.value.status_code == 503
    assert "SUPERCRED_DEMO_CWD" in excinfo.value.message


def test_repo_root_prefers_explicit_override(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """A configured root wins even when the module path is shallow."""
    _apply_container_layout(monkeypatch)
    monkeypatch.setenv("SIGNALFUSION_DEMO_CWD", str(tmp_path))
    assert demo_runner._repo_root_for("SIGNALFUSION_DEMO_CWD") == tmp_path


def test_repo_root_still_resolves_from_the_source_tree(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The in-repo behaviour the deep-path callers rely on is unchanged."""
    for name in DEMO_ENV_VARS:
        monkeypatch.delenv(name, raising=False)
    root = demo_runner._repo_root_for("SIGNALFUSION_DEMO_CWD")
    assert (root / "d2-signalloom" / "apps" / "fe-signalloom").is_dir()


# ── The endpoint that 500s in production ─────────────────────────────────────


def test_signalfusion_status_reports_unavailable_instead_of_500(
    container_client: TestClient,
) -> None:
    """GET /status answers the question it can answer, truthfully.

    The pod has no demo scripts in its image, so "is a script available?" has
    a correct answer — no. Returning it as 200/false lets the dashboard render
    its existing banner; the 500 gave the operator nothing.
    """
    response = container_client.get(
        "/api/demo/signalfusion/status", headers=_bearer(SUPERADMIN_SUBJECT)
    )
    assert response.status_code == 200
    assert response.json()["script_available"] is False


def test_supercred_status_reports_unavailable_instead_of_500(
    container_client: TestClient,
) -> None:
    """The SuperCred status route shares the defect and the fix."""
    response = container_client.get(
        "/api/demo/supercred/status", headers=_bearer(SUPERADMIN_SUBJECT)
    )
    assert response.status_code == 200
    assert response.json()["script_available"] is False


def test_status_still_requires_superadmin_under_container_layout(
    container_client: TestClient,
) -> None:
    """Degrading gracefully must not degrade the authorisation check.

    A fix that turns a crash into a 200 is exactly the shape of change that
    can widen an endpoint by accident, so the guard is asserted alongside it.
    """
    response = container_client.get("/api/demo/signalfusion/status")
    assert response.status_code in (401, 403)


def test_starting_a_run_fails_loudly_when_root_is_unresolvable(
    container_client: TestClient,
) -> None:
    """Reporting is allowed to degrade; executing is not.

    A run cannot proceed without a script path, so the request must fail with
    the actionable configuration error rather than silently doing nothing.
    """
    response = container_client.post(
        "/api/demo/signalfusion/runs",
        json={"step": "1"},
        headers=_bearer(SUPERADMIN_SUBJECT),
    )
    assert response.status_code == 503
    body = response.json()["error"]
    assert body["code"] in ("demo_root_unresolved", "demo_script_unavailable")
    assert "SIGNALFUSION_DEMO_CWD" in body["message"]
