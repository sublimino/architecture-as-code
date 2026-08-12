"""The /evidence endpoint must never turn a broken probe into a confident claim.

The card this replaces derived six lifecycle steps from `!!agent.id` and printed
hardcoded timestamps, so "completed" carried no information. The replacement is
only better if its failure modes are loud: a missing script, a crashing script
and a script emitting garbage must each surface as an error, never as an empty
or cheerful result — an empty step list renders identically to "nothing is
deployed", which is exactly the confusion being fixed.
"""
from __future__ import annotations

import json
import os
import stat
import subprocess
from pathlib import Path

import pytest

import demo_runner
from api_compat import APIError


def _write_script(tmp_path: Path, body: str) -> Path:
    path = tmp_path / "evidence.sh"
    path.write_text("#!/usr/bin/env bash\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


@pytest.fixture(autouse=True)
def _clear_env(monkeypatch):
    monkeypatch.delenv(demo_runner._ENV_EVIDENCE_SCRIPT, raising=False)


@pytest.mark.asyncio
async def test_returns_the_scripts_evidence_verbatim(tmp_path, monkeypatch):
    payload = {
        "generated_at": "2026-08-12T00:00:00Z",
        "source": "supercred-evidence.sh",
        "steps": [
            {
                "step": 1,
                "label": "Agent Deployment",
                "state": "observed",
                "command": "kubectl -n fe-signalloom-agents get pod -l signalloom.ai/supercred=true",
                "detail": "true",
                "summary": "Agent pod is running and ready",
            }
        ],
    }
    script = _write_script(tmp_path, f"cat <<'EOF'\n{json.dumps(payload)}\nEOF\n")
    monkeypatch.setenv(demo_runner._ENV_EVIDENCE_SCRIPT, str(script))

    result = await demo_runner.credential_chain_evidence(tenant_id="t")

    assert result.source == "supercred-evidence.sh"
    assert len(result.steps) == 1
    # The command travels to the browser intact. Truncating or normalising it
    # would defeat the point: a debugger must be able to paste and rerun it.
    assert result.steps[0].command.startswith("kubectl -n fe-signalloom-agents")
    assert result.steps[0].state == "observed"


@pytest.mark.asyncio
async def test_missing_script_is_503_not_an_empty_lifecycle(tmp_path, monkeypatch):
    monkeypatch.setenv(demo_runner._ENV_EVIDENCE_SCRIPT, str(tmp_path / "nope.sh"))
    with pytest.raises(APIError) as excinfo:
        await demo_runner.credential_chain_evidence(tenant_id="t")
    assert excinfo.value.status_code == 503
    assert excinfo.value.code == "evidence_script_unavailable"


@pytest.mark.asyncio
async def test_a_crashing_probe_is_502_not_a_silent_pass(tmp_path, monkeypatch):
    script = _write_script(tmp_path, "echo 'boom' >&2\nexit 3\n")
    monkeypatch.setenv(demo_runner._ENV_EVIDENCE_SCRIPT, str(script))
    with pytest.raises(APIError) as excinfo:
        await demo_runner.credential_chain_evidence(tenant_id="t")
    assert excinfo.value.status_code == 502
    assert excinfo.value.code == "evidence_failed"


@pytest.mark.asyncio
async def test_malformed_output_is_502_rather_than_no_evidence(tmp_path, monkeypatch):
    # A zero-exit script printing junk is the nastiest case: it looks healthy.
    script = _write_script(tmp_path, "echo 'not json at all'\n")
    monkeypatch.setenv(demo_runner._ENV_EVIDENCE_SCRIPT, str(script))
    with pytest.raises(APIError) as excinfo:
        await demo_runner.credential_chain_evidence(tenant_id="t")
    assert excinfo.value.status_code == 502
    assert excinfo.value.code == "evidence_malformed"


@pytest.mark.asyncio
async def test_child_environment_stays_allowlisted(tmp_path, monkeypatch):
    """The probe is read-only, which is not a reason to hand it os.environ.

    The module's threat model names the fixed child environment as a security
    boundary. It must also FORWARD the in-cluster API-server coordinates, or
    every probe reports "unavailable" from inside the cluster -- the failure
    that silently broke every dashboard-invoked demo step on 2026-08-03.
    """
    script = _write_script(
        tmp_path,
        "printf '{\"generated_at\":\"x\",\"source\":\"s\",\"steps\":[]}'\n"
        "printf '%s' \"${SECRET_TOKEN:-}\" >&2\n",
    )
    monkeypatch.setenv(demo_runner._ENV_EVIDENCE_SCRIPT, str(script))
    monkeypatch.setenv("SECRET_TOKEN", "must-not-leak")
    monkeypatch.setenv("KUBERNETES_SERVICE_HOST", "10.96.0.1")

    captured: dict[str, object] = {}
    real_run = subprocess.run

    def _capture(*args, **kwargs):
        captured.update(kwargs)
        return real_run(*args, **kwargs)

    monkeypatch.setattr(demo_runner.subprocess, "run", _capture)
    await demo_runner.credential_chain_evidence(tenant_id="t")

    env = captured["env"]
    assert "SECRET_TOKEN" not in env, "child inherited a non-allowlisted variable"
    assert env.get("KUBERNETES_SERVICE_HOST") == "10.96.0.1", (
        "without the API-server coordinates every probe reports unavailable in-cluster"
    )


@pytest.mark.asyncio
async def test_state_vocabulary_has_no_completed(tmp_path, monkeypatch):
    """`completed` is the word that got us here.

    A step may only be observed / absent / unavailable. If a future change
    reintroduces a state that asserts progress without evidence, this fails.
    """
    payload = {
        "generated_at": "x",
        "source": "s",
        "steps": [
            {"step": i, "label": f"s{i}", "state": st, "command": "c", "detail": "d", "summary": "m"}
            for i, st in enumerate(["observed", "absent", "unavailable"], start=1)
        ],
    }
    script = _write_script(tmp_path, f"cat <<'EOF'\n{json.dumps(payload)}\nEOF\n")
    monkeypatch.setenv(demo_runner._ENV_EVIDENCE_SCRIPT, str(script))

    result = await demo_runner.credential_chain_evidence(tenant_id="t")
    assert {s.state for s in result.steps} <= {"observed", "absent", "unavailable"}
    assert not any(s.state == "completed" for s in result.steps)
