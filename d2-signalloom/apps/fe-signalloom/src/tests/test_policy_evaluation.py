"""Adversarial tests for Policy-as-Code CEL evaluation and diagnostics.

Tests:
1. CEL syntax errors: unbalanced brackets, unexpected tokens, trailing operators.
2. CEL type errors: unsupported binary operations between incompatible types.
3. CEL undefined variables: undeclared root variable identifiers.
4. CEL malicious expressions: ReDoS patterns, code injection vectors, oversized payloads.
5. Structured diagnostics verification: line, column, reason, error_type.
6. Absolute rejection of 500 errors and traceback leaks.
"""
import pytest
from httpx import ASGITransport, AsyncClient

from conftest import EAP_ALICE, eap_bearer
from main import app
from policy_evaluation import (
    calculate_posture_score,
    evaluate_cel_expression,
    validate_cel_expression,
)

EAP_AUTHENTICATED = True


def test_cel_validation_valid_expressions():
    """Verify syntactically valid and safe CEL expressions pass validation."""
    valid_expressions = [
        "true",
        "false",
        "has(agent.security_profile)",
        "has(agent.security_profile) && agent.security_profile.secure_by_default == true",
        "object.spec.containers.all(c, c.securityContext.runAsNonRoot == true)",
        "request.tool_call.action in ['exec', 'write_file']",
        "agent.model == 'claude-3-5-sonnet'",
        "manifest.metadata.name != ''",
    ]
    for expr in valid_expressions:
        res = validate_cel_expression(expr)
        assert res.valid is True, f"Expected {expr!r} to be valid, got: {res.diagnostics}"
        assert res.diagnostics is None


def test_cel_validation_syntax_errors():
    """Verify syntax errors return structured diagnostics with syntax location and reason."""
    syntax_error_cases = [
        ("agent.model in ['gpt-4o'", "Unclosed opening bracket", "syntax_error"),
        ("invalid.cel ?::: ?? broken", "Invalid ternary or coalescing operator syntax", "syntax_error"),
        ("agent.model === 'gpt-4o'", "JavaScript strict equality", "syntax_error"),
        ("has(agent.id) &&", "Trailing operator without right-hand operand", "syntax_error"),
        ("agent.name == 'unclosed", "Unterminated string literal", "syntax_error"),
        ("(((agent.id == 'test')", "Unclosed opening bracket", "syntax_error"),
        ("agent.id == 'test')))", "Unmatched closing bracket", "syntax_error"),
    ]
    for expr, expected_reason_substr, expected_type in syntax_error_cases:
        res = validate_cel_expression(expr)
        assert res.valid is False, f"Expected {expr!r} to be invalid"
        assert res.diagnostics is not None
        assert res.diagnostics.error_type == expected_type
        assert res.diagnostics.line >= 1
        assert res.diagnostics.column >= 1
        assert expected_reason_substr.lower() in res.diagnostics.reason.lower()


def test_cel_validation_type_errors():
    """Verify type mismatches return structured type_error diagnostics."""
    type_error_cases = [
        ("'prefix' + 42", "type_error"),
        ("agent.name + 42", "type_error"),
        ("100 + 'suffix'", "type_error"),
    ]
    for expr, expected_type in type_error_cases:
        res = validate_cel_expression(expr)
        assert res.valid is False, f"Expected type error for {expr!r}"
        assert res.diagnostics is not None
        assert res.diagnostics.error_type == expected_type
        assert "type error" in res.diagnostics.reason.lower()
        assert res.diagnostics.line >= 1
        assert res.diagnostics.column >= 1


def test_cel_validation_undefined_variables():
    """Verify undeclared root variable identifiers are detected and reported."""
    undefined_cases = [
        ("unknown_var == true", "unknown_var"),
        ("foo.bar == 'baz'", "foo"),
        ("unregistered_root.field == 123", "unregistered_root"),
    ]
    for expr, var_name in undefined_cases:
        res = validate_cel_expression(expr)
        assert res.valid is False, f"Expected undefined variable error for {expr!r}"
        assert res.diagnostics is not None
        assert res.diagnostics.error_type == "undefined_variable"
        assert var_name in res.diagnostics.reason
        assert "root variables must be one of" in res.diagnostics.reason


def test_cel_validation_malicious_expressions():
    """Verify ReDoS patterns, code injection vectors, and oversized expressions are rejected."""
    malicious_cases = [
        # ReDoS nested quantifiers
        ("agent.id.matches('(a+)+$')", "ReDoS", "malicious_expression"),
        ("agent.id.matches('^(a|aa)+$')", "ReDoS", "malicious_expression"),
        # Code injection vectors
        ("__import__('os').system('id')", "Dangerous token", "malicious_expression"),
        ("eval('1 + 1')", "Dangerous token", "malicious_expression"),
        ("exec('import sys')", "Dangerous token", "malicious_expression"),
        ("subprocess.Popen(['ls'])", "Dangerous token", "malicious_expression"),
        ("__proto__.polluted = true", "Dangerous token", "malicious_expression"),
        # Oversized expression (> 4096 bytes)
        ("agent.model == 'a' && " * 300 + "true", "maximum allowed length", "malicious_expression"),
    ]
    for expr, expected_substr, expected_type in malicious_cases:
        res = validate_cel_expression(expr)
        assert res.valid is False, f"Expected malicious rejection for {expr[:40]!r}"
        assert res.diagnostics is not None
        assert res.diagnostics.error_type == expected_type
        assert expected_substr.lower() in res.diagnostics.reason.lower()


def test_cel_safe_evaluation_without_crashing():
    """Verify evaluate_cel_expression handles valid contexts and catches errors safely."""
    context = {
        "agent": {
            "id": "agent-1",
            "model": "claude-3-5-sonnet",
            "security_profile": {"secure_by_default": True},
        },
        "object": {
            "spec": {
                "containers": [
                    {"name": "worker", "securityContext": {"runAsNonRoot": True}},
                ],
            },
        },
    }

    # 1. Valid matching expression
    res1 = evaluate_cel_expression("has(agent.security_profile) && agent.security_profile.secure_by_default == true", context)
    assert res1.compliant is True
    assert res1.error is None

    # 2. Valid non-matching expression
    res2 = evaluate_cel_expression("agent.model == 'gpt-4o'", context)
    assert res2.compliant is False
    assert res2.error is None

    # 3. Invalid syntax evaluated safely without exception
    res3 = evaluate_cel_expression("broken ?::: syntax", context)
    assert res3.compliant is False
    assert res3.error is not None
    assert res3.diagnostics is not None
    assert res3.diagnostics.error_type == "syntax_error"


@pytest.mark.asyncio
async def test_api_policies_validate_endpoint():
    """Verify POST /api/v1/policies/validate returns 200 on valid and 422 on invalid CEL."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # Valid
        valid_payload = {"expression": "has(agent.id) && agent.model == 'claude'"}
        resp = await client.post("/api/v1/policies/validate", json=valid_payload, headers=eap_bearer(EAP_ALICE))
        assert resp.status_code == 200
        assert resp.json()["valid"] is True

        # Invalid syntax
        invalid_payload = {"expression": "invalid.syntax ?::: broken"}
        resp_invalid = await client.post("/api/v1/policies/validate", json=invalid_payload, headers=eap_bearer(EAP_ALICE))
        assert resp_invalid.status_code == 422
        data = resp_invalid.json()
        assert data["error"] == "cel_validation_error"
        assert "diagnostics" in data
        assert data["diagnostics"]["error_type"] == "syntax_error"
        assert data["diagnostics"]["line"] >= 1
        assert data["diagnostics"]["column"] >= 1

        # Traceback leak prevention: ensure no internal Python tracebacks
        assert "Traceback" not in resp_invalid.text
        assert "File \"" not in resp_invalid.text


@pytest.mark.asyncio
async def test_api_policies_evaluate_adversarial_rejection():
    """Verify POST /api/v1/policies/evaluate rejects invalid or malicious CEL with 422 and diagnostics."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # 1. Malicious ReDoS expression in rule
        malicious_payload = {
            "rules": [
                {
                    "id": "r-malicious",
                    "cel_expression": "agent.id.matches('(a+)+$')",
                }
            ],
            "agent": {"id": "test"},
        }
        resp = await client.post("/api/v1/policies/evaluate", json=malicious_payload, headers=eap_bearer(EAP_ALICE))
        assert resp.status_code == 422
        data = resp.json()
        assert data["error"] == "cel_validation_error"
        assert data["diagnostics"]["error_type"] == "malicious_expression"
        assert "Traceback" not in resp.text

        # 2. Syntax error in single expression
        syntax_payload = {
            "cel_expression": "agent.model in ['gpt-4o'",
            "agent": {"model": "gpt-4o"},
        }
        resp_syn = await client.post("/api/v1/policies/evaluate", json=syntax_payload, headers=eap_bearer(EAP_ALICE))
        assert resp_syn.status_code == 422
        data_syn = resp_syn.json()
        assert data_syn["error"] == "cel_validation_error"
        assert data_syn["diagnostics"]["error_type"] == "syntax_error"
        assert "Traceback" not in resp_syn.text

        # 3. Undefined variable in rule
        undef_payload = {
            "rules": [
                {
                    "id": "r-undef",
                    "cel_expression": "unregistered_entity.score > 90",
                }
            ],
        }
        resp_undef = await client.post("/api/v1/policies/evaluate", json=undef_payload, headers=eap_bearer(EAP_ALICE))
        assert resp_undef.status_code == 422
        data_undef = resp_undef.json()
        assert data_undef["diagnostics"]["error_type"] == "undefined_variable"
        assert "Traceback" not in resp_undef.text


@pytest.mark.asyncio
async def test_api_policies_bundle_registration_adversarial_rejection():
    """Verify POST /api/v1/policies/bundles rejects malformed bundles upfront."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # 1. Empty bundle rules
        empty_payload = {
            "framework_id": "eu-ai-act",
            "version": "v2.2.0",
            "rules": [],
        }
        resp_empty = await client.post("/api/v1/policies/bundles", json=empty_payload, headers=eap_bearer(EAP_ALICE))
        assert resp_empty.status_code == 400
        err_obj = resp_empty.json()["error"]
        assert (err_obj["code"] if isinstance(err_obj, dict) else err_obj) == "empty_bundle"

        # 2. Bundle with a broken rule CEL expression
        broken_bundle_payload = {
            "framework_id": "eu-ai-act",
            "version": "v2.2.0",
            "rules": [
                {
                    "id": "rule-valid",
                    "name": "Valid rule",
                    "cel_expression": "true",
                },
                {
                    "id": "rule-broken",
                    "name": "Broken rule",
                    "cel_expression": "agent.id == 'unclosed",
                },
            ],
        }
        resp_broken = await client.post("/api/v1/policies/bundles", json=broken_bundle_payload, headers=eap_bearer(EAP_ALICE))
        assert resp_broken.status_code == 422
        data_broken = resp_broken.json()
        assert data_broken["error"] == "cel_validation_error"
        assert data_broken["rule_id"] == "rule-broken"
        assert data_broken["diagnostics"]["error_type"] == "syntax_error"
        assert "Traceback" not in resp_broken.text


def test_hostile_agent_vectors_cel_evaluation():
    """Verify all 5 hostile agent vectors fail their target CEL controls, and compliant variants pass."""
    # ─── Vector 1 (Root Breakout) ────────────────────────────────────────────────
    v1_hostile = {
        "object": {
            "spec": {
                "containers": [
                    {
                        "name": "agent-hostile-root-breakout",
                        "securityContext": {
                            "runAsNonRoot": False,
                            "runAsUser": 0,
                            "allowPrivilegeEscalation": True,
                        },
                    }
                ]
            }
        }
    }
    v1_compliant = {
        "object": {
            "spec": {
                "containers": [
                    {
                        "name": "agent-compliant",
                        "securityContext": {
                            "runAsNonRoot": True,
                            "runAsUser": 65532,
                            "allowPrivilegeEscalation": False,
                        },
                    }
                ]
            }
        }
    }
    cis_5_2_6 = "object.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.runAsNonRoot) && c.securityContext.runAsNonRoot == true)"
    cis_5_2_5 = "object.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.allowPrivilegeEscalation) && c.securityContext.allowPrivilegeEscalation == false)"

    assert evaluate_cel_expression(cis_5_2_6, v1_hostile).compliant is False
    assert evaluate_cel_expression(cis_5_2_5, v1_hostile).compliant is False
    assert evaluate_cel_expression(cis_5_2_6, v1_compliant).compliant is True
    assert evaluate_cel_expression(cis_5_2_5, v1_compliant).compliant is True

    # ─── Vector 2 (Host Hijacker) ────────────────────────────────────────────────
    v2_hostile = {
        "object": {
            "spec": {
                "hostPID": True,
                "hostIPC": True,
                "hostNetwork": True,
            }
        }
    }
    v2_compliant = {
        "object": {
            "spec": {
                "hostPID": False,
                "hostIPC": False,
                "hostNetwork": False,
            }
        }
    }
    cis_5_2_2 = "(!has(object.spec.hostPID) || object.spec.hostPID == false) && (!has(object.spec.hostIPC) || object.spec.hostIPC == false) && (!has(object.spec.hostNetwork) || object.spec.hostNetwork == false)"

    assert evaluate_cel_expression(cis_5_2_2, v2_hostile).compliant is False
    assert evaluate_cel_expression(cis_5_2_2, v2_compliant).compliant is True

    # ─── Vector 3 (Token Harvester) ──────────────────────────────────────────────
    v3_hostile = {
        "object": {
            "spec": {
                "automountServiceAccountToken": True,
                "containers": [
                    {
                        "name": "agent-hostile-token-harvester",
                        "ports": [{"containerPort": 4444}],
                    }
                ],
            }
        }
    }
    v3_compliant = {
        "object": {
            "spec": {
                "automountServiceAccountToken": False,
                "containers": [
                    {
                        "name": "agent-compliant",
                        "ports": [{"containerPort": 8080}],
                    }
                ],
            }
        }
    }
    cis_5_7_1 = "!has(object.spec.automountServiceAccountToken) || object.spec.automountServiceAccountToken == false"
    cra_ports = "object.spec.containers.all(c, !has(c.ports) || c.ports.all(p, p.containerPort in [8080, 8443, 9090]))"

    assert evaluate_cel_expression(cis_5_7_1, v3_hostile).compliant is False
    assert evaluate_cel_expression(cra_ports, v3_hostile).compliant is False
    assert evaluate_cel_expression(cis_5_7_1, v3_compliant).compliant is True
    assert evaluate_cel_expression(cra_ports, v3_compliant).compliant is True

    # ─── Vector 4 (Syscall Bypass) ───────────────────────────────────────────────
    v4_hostile = {
        "object": {
            "spec": {
                "securityContext": {
                    "seccompProfile": {"type": "Unconfined"},
                }
            }
        }
    }
    v4_compliant = {
        "object": {
            "spec": {
                "securityContext": {
                    "seccompProfile": {"type": "RuntimeDefault"},
                }
            }
        }
    }
    cis_5_7_4 = 'has(object.spec.securityContext) && has(object.spec.securityContext.seccompProfile) && object.spec.securityContext.seccompProfile.type in ["RuntimeDefault", "Localhost"]'

    assert evaluate_cel_expression(cis_5_7_4, v4_hostile).compliant is False
    assert evaluate_cel_expression(cis_5_7_4, v4_compliant).compliant is True

    # ─── Vector 5 (Rogue Telemetry & Unauthorized Tool Exec) ────────────────────
    v5_hostile = {
        "request": {
            "tool_call": {"action": "modify_iam"},
            "context": {"claims": []},
        }
    }
    v5_compliant = {
        "request": {
            "tool_call": {"action": "modify_iam"},
            "context": {"claims": [{"type": "human_approval_svid", "valid": True}]},
        }
    }
    art_14 = "request.tool_call.action in ['exec', 'write_file', 'modify_iam'] ? (has(request.context.claims) && request.context.claims.exists(c, c.type == 'human_approval_svid' && c.valid == true)) : true"

    assert evaluate_cel_expression(art_14, v5_hostile).compliant is False
    assert evaluate_cel_expression(art_14, v5_compliant).compliant is True


@pytest.mark.asyncio
async def test_api_policies_evaluate_hostile_agent_vectors():
    """Verify POST /api/v1/policies/evaluate correctly evaluates and flags hostile vectors as non-compliant."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # Vector 1 Root Breakout via API evaluate
        payload = {
            "expression": "object.spec.containers.all(c, has(c.securityContext) && has(c.securityContext.runAsNonRoot) && c.securityContext.runAsNonRoot == true)",
            "context": {
                "object": {
                    "spec": {
                        "containers": [
                            {
                                "name": "hostile-root",
                                "securityContext": {"runAsNonRoot": False, "runAsUser": 0},
                            }
                        ]
                    }
                }
            },
        }
        resp = await client.post("/api/v1/policies/evaluate", json=payload, headers=eap_bearer(EAP_ALICE))
        assert resp.status_code == 200
        data = resp.json()
        assert data["compliant"] is False

        # Vector 2 Host Hijacker via API evaluate
        payload_v2 = {
            "expression": "(!has(object.spec.hostPID) || object.spec.hostPID == false) && (!has(object.spec.hostIPC) || object.spec.hostIPC == false) && (!has(object.spec.hostNetwork) || object.spec.hostNetwork == false)",
            "context": {
                "object": {
                    "spec": {"hostPID": True, "hostIPC": True, "hostNetwork": True}
                }
            },
        }
        resp_v2 = await client.post("/api/v1/policies/evaluate", json=payload_v2, headers=eap_bearer(EAP_ALICE))
        assert resp_v2.status_code == 200
        assert resp_v2.json()["compliant"] is False
