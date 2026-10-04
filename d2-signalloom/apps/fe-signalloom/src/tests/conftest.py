"""Suite-wide fixtures (introduced by EAPR-P2-1).

Three things live here, and only three:

1. ``EAPClient`` + ``eap_bearer`` — a *real-token* client for the EAP suites.
   The five EAP routers are mounted behind ``api_compat.authenticated_principal``
   (router-level ``dependencies=``), so a test that calls them must present a
   Dex-style JWT.  The client mints one per request through the same RSA/JWKS
   path the production verifier uses; nothing here bypasses or disables the
   dependency.  Modules opt in by declaring ``EAP_AUTHENTICATED = True`` at
   module scope, which turns on the JWT verifier settings for their tests.
   The default-deny suite deliberately uses the raw ``TestClient`` and no
   opt-in, so the guard it provides is never weakened by this file.

2. ``fresh_tenant_ownership`` — an explicit (not autouse) empty
   ``customer_hash -> tenant`` ownership map for tests that seed two tenants.

3. ``_eap_teardown_kubectl_stub`` — stubs the kubectl subprocess boundary
   used by the two cluster-dependent teardown stages (drain_routes,
   delete_namespace), for modules that opt in via
   ``MOCK_KUBECTL_TEARDOWN = True``. See its docstring.

4. ``pytest_configure`` — the hermetic cluster guard.  Before any test runs it
   puts guard executables for every cluster/runtime CLI first on ``PATH`` and
   points ``KUBECONFIG`` at an empty config, so no test can act on a real
   cluster whatever the caller's environment holds.  A guard that was reached
   fails the session in ``pytest_sessionfinish``.

Nothing else is autouse.  In particular no fixture here sets ``DATABASE_URL``,
touches ``api_compat._get_pool`` or changes ``settings`` for modules that did
not opt in.
"""
from __future__ import annotations

import os
import shutil
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace
from typing import Any

# Ensure test salt is present during pytest test collection / module imports
os.environ.setdefault("SIGNAL_LOOM_EAP_SALT", "test-eap-salt-2026")

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

import api_compat
import eap_tenancy
from api_compat import settings

EAP_ISSUER = "https://issuer.test/dex"
EAP_AUDIENCE = "signalloom-api"
EAP_AZP = "signalloom-dashboard"
EAP_KEY_ID = "eap-test-key"

#: Two tenants.  Always two: a single-tenant fixture cannot detect a missing
#: tenant filter, because every row it can return is the caller's own.
EAP_ALICE, EAP_TENANT_A = "alice", "tenant-a"
EAP_BOB, EAP_TENANT_B = "bob", "tenant-b"
#: An operator: a tenant-a principal that is also on the superadmin subject
#: allow-list.  Process-wide reaper controls (reap-now, pause/resume, status,
#: metrics) are operator-only; alice and bob are plain tenants and get 403.
EAP_OPERATOR = "operator"
EAP_SUBJECT_TENANTS = {EAP_ALICE: EAP_TENANT_A, EAP_BOB: EAP_TENANT_B, EAP_OPERATOR: EAP_TENANT_A}
#: The process-wide reaper controls, the one place tenant binding is replaced by
#: the operator role.  Shared by the default-deny suite, the forged-header
#: suite and the sealed sweep so the three cannot disagree about the list.
EAP_OPERATOR_ONLY_ROUTES: frozenset[tuple[str, str]] = frozenset(
    {
        ("POST", "/api/v1/eap/lifecycle/reap-now"),
        ("POST", "/api/v1/eap/lifecycle/reaper/pause"),
        ("POST", "/api/v1/eap/lifecycle/reaper/resume"),
        ("GET", "/api/v1/eap/lifecycle/reaper/status"),
        ("GET", "/api/v1/eap/lifecycle/metrics"),
    }
)

_EAP_SIGNING_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class _EapJwkClient:
    """Stands in for the JWKS endpoint: knows exactly one key, by ``kid``."""

    def get_signing_key_from_jwt(self, token: str) -> SimpleNamespace:
        if jwt.get_unverified_header(token).get("kid") != EAP_KEY_ID:
            raise jwt.PyJWKClientError("unknown test key")
        return SimpleNamespace(key=_EAP_SIGNING_KEY.public_key())


def eap_token_for(subject: str = EAP_ALICE, *, lifetime: int = 300, extra_claims: dict[str, Any] | None = None) -> str:
    """An RS256 token the production verifier accepts, for ``subject``."""
    now = int(time.time())
    claims: dict[str, Any] = {
        "iss": EAP_ISSUER,
        "aud": EAP_AUDIENCE,
        "sub": subject,
        "iat": now,
        "nbf": now,
        "exp": now + lifetime,
        "azp": EAP_AZP,
    }
    if extra_claims:
        claims.update(extra_claims)
    return jwt.encode(claims, _EAP_SIGNING_KEY, algorithm="RS256", headers={"kid": EAP_KEY_ID, "typ": "JWT"})


def eap_bearer(subject: str = EAP_ALICE) -> dict[str, str]:
    """``Authorization`` header for ``subject`` (alice -> tenant-a, bob -> tenant-b)."""
    return {"Authorization": f"Bearer {eap_token_for(subject)}"}


def _has_authorization(headers: Any) -> bool:
    return any(str(k).lower() == "authorization" for k in (headers or {}))


class EAPClient(TestClient):
    """``TestClient`` that authenticates every request as ``subject``.

    A caller that sets ``Authorization`` itself (another tenant, a forged or
    empty token) wins; the client only fills the header in when it is absent.
    Websocket handshakes get the same treatment.
    """

    def __init__(self, app: Any, subject: str = EAP_ALICE, **kwargs: Any) -> None:
        super().__init__(app, **kwargs)
        self.subject = subject

    def _with_bearer(self, headers: Any) -> dict[str, str]:
        merged = dict(headers or {})
        if not _has_authorization(merged):
            merged.update(eap_bearer(self.subject))
        return merged

    def request(self, method: str, url: Any, *args: Any, headers: Any = None, **kwargs: Any) -> Any:  # type: ignore[override]
        return super().request(method, url, *args, headers=self._with_bearer(headers), **kwargs)

    def websocket_connect(self, url: str, subprotocols: Any = None, **kwargs: Any) -> Any:  # type: ignore[override]
        kwargs["headers"] = self._with_bearer(kwargs.get("headers"))
        return super().websocket_connect(url, subprotocols, **kwargs)


def configure_eap_jwt(monkeypatch: pytest.MonkeyPatch) -> None:
    """Point the production verifier at the test issuer and key.  Restored by monkeypatch."""
    monkeypatch.setattr(settings, "api_jwt_issuer", EAP_ISSUER)
    monkeypatch.setattr(settings, "api_jwt_audience", EAP_AUDIENCE)
    monkeypatch.setattr(settings, "api_jwt_authorized_party", EAP_AZP)
    monkeypatch.setattr(settings, "api_jwks_url", "https://issuer.test/keys")
    monkeypatch.setattr(settings, "api_subject_tenants", dict(EAP_SUBJECT_TENANTS))
    monkeypatch.setattr(settings, "api_superadmin_subjects", {EAP_OPERATOR})
    monkeypatch.setattr(settings, "api_superadmin_emails", set())
    monkeypatch.setattr(api_compat, "_jwk_client", lambda _url: _EapJwkClient())


@pytest.fixture
def fresh_tenant_ownership(monkeypatch: pytest.MonkeyPatch) -> eap_tenancy.TenantOwnership:
    """An empty customer_hash -> tenant map for this test only.

    Not autouse on purpose: the EAP engines (environment registry, lifecycle
    manager, tenant boundaries, scenario manager) are module-level singletons
    that several suites read across tests, and an ownership map reset between
    tests would orphan the records those suites created a test earlier.  The
    map is therefore as long-lived as the engines it binds, and a test that
    needs two tenants over a clean slate asks for this fixture explicitly.
    """
    ownership = eap_tenancy.TenantOwnership()
    monkeypatch.setattr(eap_tenancy, "GLOBAL_TENANT_OWNERSHIP", ownership)
    return ownership


@pytest.fixture(autouse=True)
def _eap_jwt_env(request: pytest.FixtureRequest, monkeypatch: pytest.MonkeyPatch):
    """JWT verifier settings for modules that declare ``EAP_AUTHENTICATED = True``."""
    if getattr(request.module, "EAP_AUTHENTICATED", False):
        configure_eap_jwt(monkeypatch)
    yield


@pytest.fixture
def eap_jwt_env(monkeypatch: pytest.MonkeyPatch):
    """Explicit form of the same settings, for tests in modules that did not opt in."""
    configure_eap_jwt(monkeypatch)
    yield


@pytest.fixture(autouse=True)
def _fresh_subject_binding_cache():
    """``authenticated_principal`` caches subject -> tenant bindings for a short
    TTL. The cache is module-level and would otherwise let one test's binding
    (or its "no binding" verdict) leak into the next."""
    api_compat.invalidate_subject_binding()
    yield
    api_compat.invalidate_subject_binding()


@pytest.fixture(autouse=True)
def _eap_test_salt(monkeypatch: pytest.MonkeyPatch):
    """Provide a default test salt in the environment for offline hermetic test runs."""
    import os
    if "SIGNAL_LOOM_EAP_SALT" not in os.environ:
        monkeypatch.setenv("SIGNAL_LOOM_EAP_SALT", "test-eap-salt-2026")
    yield


#: Every CLI that can act on a cluster, a mesh or a container runtime.  The
#: unit suite reaches none of them: tests/conftest.py shadows each with a guard.
GUARDED_CLUSTER_CLIS: tuple[str, ...] = ("kubectl", "docker", "podman", "helm", "flux", "kind", "tailscale", "bao")
HERMETIC_GUARD_EXIT = 97

_GUARD_SCRIPT = """#!/bin/sh
# Written by tests/conftest.py. A unit test reached a real cluster/runtime CLI.
printf "hermetic guard: unit suite invoked real '%s'\\n" "$(basename "$0") $*" >&2
if [ "${HERMETIC_GUARD_SELFTEST:-}" != "1" ]; then
  printf '%s  [%s]\\n' "$(basename "$0") $*" "${PYTEST_CURRENT_TEST:-unknown test}" >> "$HERMETIC_GUARD_DIR/invocations.log"
fi
exit 97
"""

_EMPTY_KUBECONFIG = "apiVersion: v1\nkind: Config\nclusters: []\ncontexts: []\nusers: []\ncurrent-context: \"\"\n"


def pytest_configure(config: pytest.Config) -> None:
    """Make the suite hermetic before any test module is imported.

    Guards for every CLI in ``GUARDED_CLUSTER_CLIS`` go first on ``PATH``; each
    exits ``HERMETIC_GUARD_EXIT`` and logs the call.  ``KUBECONFIG`` points at
    a readable config that names no cluster, so even a kubectl found by
    absolute path has nothing to talk to.  The overrides that name a kubectl
    binary directly are removed so resolution goes through ``PATH``; tests that
    need a fake kubectl set them with ``monkeypatch``.
    """
    guard_dir = Path(tempfile.mkdtemp(prefix="fe-hermetic-guard-"))
    for cli in GUARDED_CLUSTER_CLIS:
        path = guard_dir / cli
        path.write_text(_GUARD_SCRIPT)
        path.chmod(0o755)
    (guard_dir / "invocations.log").write_text("")
    kubeconfig = guard_dir / "kubeconfig"
    kubeconfig.write_text(_EMPTY_KUBECONFIG)
    os.environ["HERMETIC_GUARD_DIR"] = str(guard_dir)
    os.environ["PATH"] = f"{guard_dir}{os.pathsep}{os.environ.get('PATH', '')}"
    os.environ["KUBECONFIG"] = str(kubeconfig)
    for override in ("SIGNALLOOM_KUBECTL", "SIGNALLOOM_TEARDOWN_KUBECTL", "DOCKER_HOST"):
        os.environ.pop(override, None)


def pytest_sessionfinish(session: pytest.Session, exitstatus: int) -> None:
    """Fail the run if any test reached a guarded CLI, even if it passed."""
    guard_dir = os.environ.get("HERMETIC_GUARD_DIR")
    if not guard_dir:
        return
    calls = (Path(guard_dir) / "invocations.log").read_text().splitlines()
    if calls:
        reporter = session.config.pluginmanager.get_plugin("terminalreporter")
        if reporter is not None:
            reporter.write_line(f"hermetic guard: {len(calls)} real cluster/runtime CLI call(s): {calls[:10]}", red=True)
        session.exitstatus = pytest.ExitCode.TESTS_FAILED


def pytest_unconfigure(config: pytest.Config) -> None:
    guard_dir = os.environ.get("HERMETIC_GUARD_DIR")
    if guard_dir and Path(guard_dir).name.startswith("fe-hermetic-guard-"):
        shutil.rmtree(guard_dir, ignore_errors=True)


@pytest.fixture(autouse=True)
def _eap_teardown_kubectl_stub(request: pytest.FixtureRequest, monkeypatch: pytest.MonkeyPatch):
    """Stub the kubectl subprocess boundary for cluster-dependent teardown
    stages, so the real 5-stage teardown pipeline can be exercised end-to-end
    in a unit suite.

    Opt in via ``MOCK_KUBECTL_TEARDOWN = True`` at module scope (same pattern
    as ``EAP_AUTHENTICATED`` above) — only the suites that drive the real
    teardown pipeline set this flag, so no other suite's behaviour changes.

    The stub is unconditional.  It used to switch itself off whenever a
    kubeconfig could be opened, on the theory that a cluster-equipped runner
    should run the stages for real; in practice that meant a developer
    machine with a working kubeconfig ran ``kubectl delete httproute`` and
    ``kubectl delete namespace`` for test tenants against whichever shared
    cluster its current context named.  Live teardown belongs to the live
    suites, never to this one.

    This patches exactly one function, ``environment_teardown.run_bounded``
    — the bounded-subprocess helper every teardown stage shells out
    through — and only short-circuits calls whose argv[0] basename is
    ``kubectl``. Concretely that is Stage 1 (drain_routes: ``kubectl get
    httproute`` / ``kubectl delete httproute``) and Stage 5
    (delete_namespace: ``kubectl delete namespace``); both only need "no
    routes found" / "rc=0" to behave as a no-op success, so returning an
    empty JSON object with returncode 0 is enough for both. Stage 4
    (evict_tailscale) also calls ``run_bounded``, but its argv[0] is
    ``bash`` (it runs ``tailscale-eap-env.sh``, already offline-safe via its
    own mock mode), so it always falls through to the real implementation
    unchanged. Stages 2 and 3 (shred_openbao, revoke_svid) never call
    ``run_bounded`` at all — they take an injectable ``client`` — so a
    failure injected there (e.g. ``test_teardown_stage_failure_sets_teardown_failed``)
    is completely unaffected by this stub and still fails for its own reason.
    """
    if not getattr(request.module, "MOCK_KUBECTL_TEARDOWN", False):
        yield
        return

    import environment_teardown

    real_run_bounded = environment_teardown.run_bounded

    def _stub_run_bounded(argv, deadline, env=None):
        exe = os.path.basename(argv[0]) if argv else ""
        if exe != "kubectl":
            return real_run_bounded(argv, deadline, env=env)
        # Both callers here only need rc=0; `kubectl get httproute -o json`
        # additionally needs its stdout to parse as "zero routes".
        return environment_teardown._Completed(0, "{}", "")

    monkeypatch.setattr(environment_teardown, "run_bounded", _stub_run_bounded)
    yield



@pytest.fixture(autouse=True)
def _signal_ingest_gateway_key(tmp_path_factory, monkeypatch):
    """Mount a test gateway key for the signal-ingest proxies (ingest_client).

    Every route that calls signal-ingest now presents fe-signalloom's gateway key, read from the
    file SIGNAL_INGEST_KEY_FILE names, and refuses with 503 when it is absent rather than sending
    an anonymous request. Tests that exercise the absent-key path override the variable themselves.
    """
    path = tmp_path_factory.mktemp("ingest-key") / "token"
    path.write_text("test-gateway-key-" + "k" * 32)
    monkeypatch.setenv("SIGNAL_INGEST_KEY_FILE", str(path))
