"""The demo script's child process must be able to reach the Kubernetes API.

The defect, observed 2026-08-03 on a live cluster: EVERY step invoked from the
dashboard failed in tens to hundreds of milliseconds having printed only its
banner line. "Reset demo" (step 5) took 333ms; phase 4 took 53ms. No error text
reached the UI, because the script's own diagnostics never ran -- kubectl exited
before the script could report anything.

`demo_runner` spawns the script with a FIXED child environment built from
`_ENV_ALLOWLIST` (the module docstring names it as one of four security
boundaries). That allowlist omitted KUBERNETES_SERVICE_HOST and
KUBERNETES_SERVICE_PORT, which is how client-go's in-cluster config -- and
therefore kubectl inside a pod -- discovers the API server. The kubelet injects
both into the pod; `_child_env()` dropped them, so the child had no server to
talk to and `set -euo pipefail` killed the script at its first kubectl call.

Why this file exists, and why it does not simply assert on `_ENV_ALLOWLIST`:

  * Asserting the tuple contains two strings is a restatement of the code. It
    goes green on any tuple with the right contents and proves nothing about
    what the child actually receives.
  * This slice has already shipped one green-unit-tests-over-a-dead-system bug:
    `script_available` passed against a script path the pod did not have. A test
    that never spawns anything repeats exactly that mistake.

So these tests spawn a REAL subprocess through the same `env=_child_env()` call
the runner uses, and assert on what the child observes. The requirement is
stated once, as REQUIRED_IN_CLUSTER_ENV, with the reason for each key -- adding
a new requirement to that list fails loudly until the allowlist carries it.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

import pytest

import demo_runner

# What an in-cluster Kubernetes client needs from the ENVIRONMENT, and only
# from the environment. Deliberately not "everything kubectl needs": the
# ServiceAccount token and the cluster CA are read from the projected volume at
# /var/run/secrets/kubernetes.io/serviceaccount/ and require no env var, so
# they are correctly absent from the allowlist and correctly absent from here.
#
# Source of truth is client-go's rest.InClusterConfig(), which errors with
# ErrNotInCluster unless BOTH of these are set and non-empty.
REQUIRED_IN_CLUSTER_ENV = {
    "KUBERNETES_SERVICE_HOST": "API server host; without it kubectl has no server to reach",
    "KUBERNETES_SERVICE_PORT": "API server port; InClusterConfig requires it alongside the host",
}

# Keys the child must NEVER receive. The allowlist is a security boundary, and
# the fix for the defect above is to widen it by name -- switching to
# os.environ would hand the demo script the API's own signing material.
FORBIDDEN_IN_CHILD_ENV = (
    "API_JWT_ISSUER",
    "API_JWKS_URL",
    "DATABASE_URL",
    "POSTGRES_PASSWORD",
    "BAO_TOKEN",
    "AWS_SECRET_ACCESS_KEY",
)


@pytest.fixture
def pod_like_environ(monkeypatch: pytest.MonkeyPatch) -> dict[str, str]:
    """The environment a kubelet gives a pod, plus secrets it must not leak."""
    injected = {
        "KUBERNETES_SERVICE_HOST": "10.96.0.1",
        "KUBERNETES_SERVICE_PORT": "443",
        "CLUSTER_NAME": "kind-osramp",
        "AGENT_NAMESPACE_CANDIDATES": "fe-signalloom-agents fe-signalloom",
    }
    for key, value in injected.items():
        monkeypatch.setenv(key, value)
    for key in FORBIDDEN_IN_CHILD_ENV:
        monkeypatch.setenv(key, f"secret-value-for-{key}")
    return injected


def _child_observed_env(env: dict[str, str]) -> dict[str, str]:
    """Env as seen by a real child spawned exactly the way the runner spawns."""
    completed = subprocess.run(
        [sys.executable, "-c", "import json, os; print(json.dumps(dict(os.environ)))"],
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(completed.stdout)


def test_child_receives_every_variable_an_in_cluster_client_needs(
    pod_like_environ: dict[str, str],
) -> None:
    observed = _child_observed_env(demo_runner._child_env())

    missing = {
        key: why for key, why in REQUIRED_IN_CLUSTER_ENV.items() if not observed.get(key)
    }
    assert not missing, (
        "the demo script's child cannot reach the Kubernetes API server. "
        f"Missing from the spawned environment: {missing}. "
        "Every step will fail at its first kubectl call, in milliseconds, "
        "with no diagnostic. Add the key to demo_runner._ENV_ALLOWLIST."
    )


def test_child_receives_the_pods_actual_values_not_placeholders(
    pod_like_environ: dict[str, str],
) -> None:
    # An allowlist that carried the key but dropped the value would fail in the
    # same instant, silent way. Assert the value survives the crossing.
    observed = _child_observed_env(demo_runner._child_env())
    for key in REQUIRED_IN_CLUSTER_ENV:
        assert observed[key] == pod_like_environ[key]


def test_child_environment_stays_an_allowlist(pod_like_environ: dict[str, str]) -> None:
    # The fix for the missing keys must not become "pass os.environ through".
    observed = _child_observed_env(demo_runner._child_env())
    leaked = [key for key in FORBIDDEN_IN_CHILD_ENV if key in observed]
    assert not leaked, f"demo script child inherited API secrets: {leaked}"


def test_child_environment_carries_nothing_beyond_the_allowlist(
    pod_like_environ: dict[str, str],
) -> None:
    # The child's environment should be exactly what _child_env() built.
    # Anything else means the boundary has been widened somewhere other than
    # _ENV_ALLOWLIST.
    #
    # LC_CTYPE is the one documented exception: CPython sets it in the child
    # itself under PEP 538 locale coercion, so it is injected by the
    # interpreter rather than inherited from the parent. It carries no data.
    interpreter_injected = {"LC_CTYPE"}

    built = demo_runner._child_env()
    observed = _child_observed_env(built)
    assert set(observed) - interpreter_injected == set(built)
    assert set(built) <= set(demo_runner._ENV_ALLOWLIST)


def test_required_keys_are_actually_reachable_from_a_real_pod_environment() -> None:
    # Guards the inverse mistake: a REQUIRED_IN_CLUSTER_ENV entry naming a
    # variable the allowlist can never supply would make this suite unfixable.
    assert set(REQUIRED_IN_CLUSTER_ENV) <= set(demo_runner._ENV_ALLOWLIST)


def test_unset_variables_are_omitted_rather_than_blanked(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Off-cluster (local dev against a kubeconfig) the KUBERNETES_* keys are
    # genuinely absent. They must be omitted, not set to "", because
    # InClusterConfig treats an empty host as "not in cluster" but other
    # tooling treats a set-but-empty variable as a configured value.
    for key in REQUIRED_IN_CLUSTER_ENV:
        monkeypatch.delenv(key, raising=False)
    built = demo_runner._child_env()
    for key in REQUIRED_IN_CLUSTER_ENV:
        assert key not in built


def test_kubectl_reports_in_cluster_config_from_the_child_environment(
    pod_like_environ: dict[str, str],
) -> None:
    """End-to-end on the real binary, when there is one to test against.

    The unit tests above prove the variables cross the boundary. This proves
    they are the variables kubectl actually acts on: given only `_child_env()`
    and no kubeconfig, kubectl must resolve a server (and fail on connect or
    on the missing ServiceAccount token) rather than fail on having no
    configuration at all.
    """
    if not any(
        os.access(os.path.join(directory, "kubectl"), os.X_OK)
        for directory in os.environ.get("PATH", "").split(os.pathsep)
        if directory
    ):
        pytest.skip("kubectl not on PATH")

    env = demo_runner._child_env()
    env.pop("KUBECONFIG", None)
    env["HOME"] = "/nonexistent-so-no-kubeconfig-is-found"

    completed = subprocess.run(
        ["kubectl", "get", "--raw", "/version", "--request-timeout=3s"],
        env=env,
        capture_output=True,
        text=True,
    )
    combined = f"{completed.stdout}\n{completed.stderr}"

    # The failure we must NOT see is the no-configuration one. Anything about
    # reaching 10.96.0.1 means the environment was understood.
    assert "no configuration has been provided" not in combined, combined
    assert "ErrNotInCluster" not in combined, combined
