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
