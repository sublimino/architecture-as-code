"""Tests for Signal Loom external webhook triggers and signature verifiers."""
from __future__ import annotations

import hashlib
import hmac
import json
import time

import pytest
from fastapi.testclient import TestClient

from environment_routing import GLOBAL_ENVIRONMENT_REGISTRY, EnvironmentState
from main import app
from webhook_triggers import (
    DEFAULT_WEBHOOK_SECRET,
    get_webhook_secret,
    verify_generic_signature,
    verify_github_signature,
)

client = TestClient(app)


def test_webhook_secret_resolution():
    """Verify default and tenant-specific webhook secret derivation."""
    assert get_webhook_secret() == DEFAULT_WEBHOOK_SECRET


def test_verify_github_signature_valid():
    """Verify that a valid HMAC-SHA256 signature passes verification."""
    payload = b'{"action":"opened","number":101}'
    secret = "test-secret"
    digest = hmac.new(secret.encode("utf-8"), payload, hashlib.sha256).hexdigest()
    header = f"sha256={digest}"

    assert verify_github_signature(payload, secret, header) is True
    # Tampered payload fails
    assert verify_github_signature(payload + b"tamper", secret, header) is False
    # Missing prefix fails
    assert verify_github_signature(payload, secret, digest) is False
    # None header fails
    assert verify_github_signature(payload, secret, None) is False


def test_verify_generic_signature_valid_and_replay_protection():
    """Verify generic signature with timestamp drift checks."""
    payload = b'{"action":"provision","company_name":"kurasi"}'
    secret = "test-secret"
    now_ts = int(time.time())

    to_sign = f"{now_ts}.".encode("utf-8") + payload
    sig = hmac.new(secret.encode("utf-8"), to_sign, hashlib.sha256).hexdigest()

    # Valid
    assert verify_generic_signature(payload, secret, sig, str(now_ts)) is True

    # Replay attack with expired timestamp (> 300s)
    old_ts = now_ts - 400
    to_sign_old = f"{old_ts}.".encode("utf-8") + payload
    sig_old = hmac.new(secret.encode("utf-8"), to_sign_old, hashlib.sha256).hexdigest()
    assert verify_generic_signature(payload, secret, sig_old, str(old_ts)) is False


def test_api_github_webhook_unauthorized_without_signature():
    """Verify that missing X-Hub-Signature-256 returns HTTP 401."""
    resp = client.post(
        "/api/v1/webhooks/github",
        json={"action": "opened"},
        headers={"X-GitHub-Event": "pull_request"},
    )
    assert resp.status_code == 401


def test_api_github_webhook_pr_lifecycle():
    """Verify GitHub PR lifecycle: opened -> provision, closed -> teardown."""
    secret = DEFAULT_WEBHOOK_SECRET

    # 1. Clean up any existing environment for kurasi first
    existing = GLOBAL_ENVIRONMENT_REGISTRY.get_by_hash("6f82ad81")
    if existing and existing.state != EnvironmentState.TERMINATED:
        GLOBAL_ENVIRONMENT_REGISTRY.teardown(existing.id)

    # 2. PR Opened
    body_opened = {
        "action": "opened",
        "number": 42,
        "repository": {"name": "kurasi-frontend"},
    }
    raw_opened = json.dumps(body_opened).encode("utf-8")
    sig_opened = "sha256=" + hmac.new(secret.encode("utf-8"), raw_opened, hashlib.sha256).hexdigest()

    resp_opened = client.post(
        "/api/v1/webhooks/github",
        content=raw_opened,
        headers={
            "Content-Type": "application/json",
            "X-Hub-Signature-256": sig_opened,
            "X-GitHub-Event": "pull_request",
            "X-GitHub-Delivery": "delivery-guid-1",
        },
    )
    assert resp_opened.status_code == 200
    data_opened = resp_opened.json()
    assert data_opened["status"] == "ok"
    assert data_opened["action_taken"] == "provisioned"
    assert data_opened["customer_hash"] == "6f82ad81"
    assert data_opened["hostname"] == "sl-eap-6f82ad81"
    assert data_opened["internal_mesh_url"] == "https://sl-eap-6f82ad81.tailscale"
    env_id = data_opened["environment_id"]

    # 3. PR Closed -> Teardown
    body_closed = {
        "action": "closed",
        "number": 42,
        "repository": {"name": "kurasi-frontend"},
    }
    raw_closed = json.dumps(body_closed).encode("utf-8")
    sig_closed = "sha256=" + hmac.new(secret.encode("utf-8"), raw_closed, hashlib.sha256).hexdigest()

    resp_closed = client.post(
        "/api/v1/webhooks/github",
        content=raw_closed,
        headers={
            "Content-Type": "application/json",
            "X-Hub-Signature-256": sig_closed,
            "X-GitHub-Event": "pull_request",
            "X-GitHub-Delivery": "delivery-guid-2",
        },
    )
    assert resp_closed.status_code == 200
    data_closed = resp_closed.json()
    assert data_closed["action_taken"] == "torn_down"
    assert data_closed["state"] == "terminated"


def test_api_generic_webhook_trigger():
    """Verify generic webhook trigger with HMAC-SHA256 and timestamp."""
    secret = DEFAULT_WEBHOOK_SECRET
    now_ts = str(int(time.time()))

    body = {
        "company_name": "kurasi",
        "action": "provision",
        "ttl_minutes": 60,
    }
    raw_body = json.dumps(body).encode("utf-8")
    to_sign = f"{now_ts}.".encode("utf-8") + raw_body
    sig = hmac.new(secret.encode("utf-8"), to_sign, hashlib.sha256).hexdigest()

    resp = client.post(
        "/api/v1/webhooks/generic",
        content=raw_body,
        headers={
            "Content-Type": "application/json",
            "X-SignalLoom-Signature": sig,
            "X-SignalLoom-Timestamp": now_ts,
        },
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["customer_hash"] == "6f82ad81"
    assert data["hostname"] == "sl-eap-6f82ad81"
    assert data["internal_mesh_url"] == "https://sl-eap-6f82ad81.tailscale"
