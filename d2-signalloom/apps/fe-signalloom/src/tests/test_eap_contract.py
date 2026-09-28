# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/tests/test_eap_contract.py
# EAPR-P3-2: Contract tests for EAP lifecycle constants and AST guard.
# ==============================================================================
import ast
from pathlib import Path
import pytest
from fastapi.testclient import TestClient

from eap_contract import (
    HEARTBEAT_WINDOW_SECONDS,
    MAX_INITIAL_TTL_MINUTES,
    MAX_LIFETIME_HOURS,
    SPIFFE_TRUST_DOMAIN,
)
from main import app
from conftest import EAP_ALICE, EAP_OPERATOR, EAP_TENANT_A, EAPClient

EAP_AUTHENTICATED = True


def test_eap_contract_value_pins():
    """Verify single source of truth value pins for EAP lifecycle contract."""
    assert MAX_LIFETIME_HOURS == 8, "MAX_LIFETIME_HOURS must be pinned to 8 hours"
    assert MAX_INITIAL_TTL_MINUTES == 480, "MAX_INITIAL_TTL_MINUTES must be pinned to 480 minutes"
    assert HEARTBEAT_WINDOW_SECONDS == 300, "HEARTBEAT_WINDOW_SECONDS must be pinned to 300 seconds"
    assert SPIFFE_TRUST_DOMAIN == "signalloom.demo", "SPIFFE_TRUST_DOMAIN must be pinned to signalloom.demo"


def test_eap_contract_ast_single_definition_guard():
    """AST walk over all src/*.py files fails on any Assign to lifecycle constants outside eap_contract.py."""
    src_dir = Path(__file__).resolve().parents[1]
    banned_targets = {"MAX_LIFETIME_HOURS", "MAX_INITIAL_TTL_MINUTES"}
    violations = []

    for py_file in sorted(src_dir.glob("*.py")):
        if py_file.name == "eap_contract.py":
            continue
        tree = ast.parse(py_file.read_text(encoding="utf-8"), filename=str(py_file))
        for node in ast.walk(tree):
            if isinstance(node, ast.Assign):
                for target in node.targets:
                    if isinstance(target, ast.Name) and target.id in banned_targets:
                        violations.append((py_file.name, node.lineno, target.id))
            elif isinstance(node, ast.AnnAssign):
                if isinstance(node.target, ast.Name) and node.target.id in banned_targets:
                    violations.append((py_file.name, node.lineno, node.target.id))

    assert violations == [], f"Found duplicate constant assignments outside eap_contract.py: {violations}"


def test_provision_initial_ttl_above_480_returns_422():
    """Provisioning with ttl_minutes > 480 returns 422 Unprocessable Entity."""
    client = EAPClient(app, EAP_ALICE)
    resp = client.post(
        "/api/v1/environments/provision",
        json={"company_name": "contract-test", "ttl_minutes": 481},
    )
    assert resp.status_code == 422, f"Expected 422 for ttl_minutes > 480, got {resp.status_code}: {resp.text}"


def test_extend_ttl_beyond_8h_ceiling_returns_422():
    """Extending environment TTL beyond 8-hour total lifetime ceiling returns 422."""
    client = EAPClient(app, EAP_ALICE)
    # 1. Provision environment with 60m TTL
    prov_resp = client.post(
        "/api/v1/environments/provision",
        json={"company_name": "contract-test-extend", "ttl_minutes": 60},
    )
    assert prov_resp.status_code in (200, 201), f"Provisioning failed: {prov_resp.text}"
    env_id = prov_resp.json()["id"]

    # 2. Attempt extension exceeding 8 hours (8 * 60 = 480 minutes total ceiling)
    # Trying to add 450 minutes when 60 minutes already allocated exceeds 480
    extend_resp = client.post(
        f"/api/v1/environments/{env_id}/extend",
        json={"additional_minutes": 450},
    )
    assert extend_resp.status_code == 422, f"Expected 422 for extension beyond 8h, got {extend_resp.status_code}: {extend_resp.text}"
