"""The unit suite can never reach a real cluster or container runtime.

tests/conftest.py puts guard executables for every cluster/runtime CLI first on
PATH and points KUBECONFIG at an empty, readable config before any test runs.
These tests pin that boundary.  The teardown test runs with a *readable*
kubeconfig on purpose: the stub it relies on used to switch itself off whenever
a kubeconfig could be opened, which made the suite issue real
``kubectl delete httproute`` / ``kubectl delete namespace`` calls against
whatever cluster that kubeconfig named.
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

import environment_teardown
from conftest import GUARDED_CLUSTER_CLIS, HERMETIC_GUARD_EXIT
from environment_teardown import StageOutcome

MOCK_KUBECTL_TEARDOWN = True


@pytest.mark.parametrize("cli", GUARDED_CLUSTER_CLIS)
def test_cluster_cli_on_path_is_the_hermetic_guard(cli: str) -> None:
    resolved = shutil.which(cli)
    assert resolved is not None
    assert Path(resolved).parent == Path(os.environ["HERMETIC_GUARD_DIR"])
    proc = subprocess.run(
        [cli, "get", "namespaces"],
        capture_output=True,
        text=True,
        env={**os.environ, "HERMETIC_GUARD_SELFTEST": "1"},
        timeout=10,
    )
    assert proc.returncode == HERMETIC_GUARD_EXIT
    assert proc.stdout == ""
    assert f"hermetic guard: unit suite invoked real '{cli} get namespaces'" in proc.stderr


def test_kubeconfig_is_readable_and_names_no_cluster() -> None:
    kubeconfig = Path(os.environ["KUBECONFIG"])
    text = kubeconfig.read_text()
    assert "clusters: []" in text
    assert "contexts: []" in text
    assert "server:" not in text


def test_teardown_kubectl_stages_are_stubbed_even_with_a_readable_kubeconfig() -> None:
    result = environment_teardown.sever_ingress_routes("a0314bec")
    assert result.outcome == StageOutcome.ALREADY_ABSENT, result.detail
    assert result.detail == "no routes for a0314bec in namespace " + environment_teardown.DEFAULT_ROUTE_NAMESPACE
