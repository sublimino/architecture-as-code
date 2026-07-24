"""Run the ADK rca_readiness eval as pytest: the same evaluation `adk web`'s
Eval tab and the `adk eval` CLI run, wrapped for CI (mirrors
demo/adk-ops-assistant/ops_assistant/eval_test.py).

Self-contained and offline: it starts the hermetic elk evidence stub
(tests/elk_stub.py) and points the pipeline's MCP fan-out at it, because
AgentEvaluator runs the REAL httpx fan-out and, unlike the unit tests,
cannot monkeypatch it. Deterministic RCA (no LLM_PROVIDER) is the reproducible
baseline; the loose ROUGE response_match in test_config.json tolerates
timestamp/model variance. The hard fault_domain / evidence / redaction
assertions are the real gate in tests/test_rca_signals.py.

    make olly-eval        # or, with the deps installed: pytest olly_sentinel/eval_test.py -v
"""

import os
import sys
from pathlib import Path

import pytest
from google.adk.evaluation.agent_evaluator import AgentEvaluator

_HERE = Path(__file__).resolve().parent      # olly_sentinel/
_SENTINEL = _HERE.parent                      # apps/sentinel/
for _p in (str(_SENTINEL), str(_SENTINEL / "tests")):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import elk_stub  # noqa: E402  (tests/elk_stub.py, the golden evidence corpus)

AGENT_MODULE = "olly_sentinel"


@pytest.fixture(scope="module", autouse=True)
def _hermetic_evidence():
    """Serve the golden incidents and aim the pipeline's MCP fan-out at the
    stub. Sets the env before importing config (so the first read picks it up)
    and patches the config attribute after (so a cached import can't defeat
    it)."""
    server = elk_stub.serve_in_thread("127.0.0.1", 0)
    url = f"http://127.0.0.1:{server.server_address[1]}"
    os.environ["MCP_URL"] = url
    import olly_sentinel.config as cfg
    cfg.MCP_URL = url
    try:
        yield
    finally:
        server.shutdown()


@pytest.mark.asyncio
async def test_rca_readiness():
    """The agent returns a coherent rca-enrichment for each seeded golden
    incident (loose response_match; the deterministic signal-check gate is
    tests/test_rca_signals.py). test_config.json is auto-discovered beside the
    dataset."""
    await AgentEvaluator.evaluate(
        agent_module=AGENT_MODULE,
        eval_dataset_file_path_or_dir=str(_HERE / "rca_readiness.test.json"),
    )
