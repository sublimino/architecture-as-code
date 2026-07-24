"""Pytest bootstrap for the sentinel unit + eval suites.

Follows the Google ADK demo conftest pattern (load .env, make the package
importable) with one deliberate inversion: it does NOT hard-fail when model
credentials are absent. Deterministic RCA (no LLM_PROVIDER) is the reproducible
baseline the gate runs on; model creds are only needed for the optional
LLM-judge metric. Side effects are limited to env + sys.path and it never
imports olly_sentinel, so MCP_URL / CONTRACTS_DIR overrides set here (or by a
fixture) land before the package's config module reads them.
"""

import os
import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent  # olly-replica/apps/sentinel

# Make the olly_sentinel package importable for adk eval / AgentEvaluator.
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

# Load the agent's .env if present (LLM provider/model, MCP_URL), like the demo.
try:
    from dotenv import load_dotenv

    load_dotenv(_HERE / "olly_sentinel" / ".env")
except Exception:  # noqa: BLE001 - dotenv is optional; env may be set directly
    pass

# The committed contracts are the fixtures; fall back to the checkout when
# CONTRACTS_DIR isn't already set (the image sets it to /contracts).
if not os.environ.get("CONTRACTS_DIR"):
    os.environ["CONTRACTS_DIR"] = str(_HERE.parents[1] / "contracts")
