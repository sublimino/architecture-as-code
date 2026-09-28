from dataclasses import FrozenInstanceError
from inspect import signature
from time import monotonic

import pytest

from environment_teardown_contract import (
    ORDERED_STAGES,
    AttributionError,
    DeadlineExceeded,
    StageExecutor,
    StageRequest,
    StageResult,
    TeardownAuthorizationError,
    TeardownError,
    TeardownSecurityError,
    TeardownStage,
)


def test_teardown_stage_contract_is_exact():
    assert [(stage.name, stage.value) for stage in TeardownStage] == [
        ("ROUTE", "route"),
        ("MESH", "mesh"),
        ("KEY_SPIRE", "key_spire"),
        ("NAMESPACE_STORAGE", "namespace_storage"),
    ]
    assert ORDERED_STAGES == tuple(TeardownStage)
    assert isinstance(ORDERED_STAGES, tuple)


def test_stage_request_is_frozen():
    request = StageRequest("0123abcd", "td-1", monotonic() + 1)
    with pytest.raises(FrozenInstanceError):
        request.customer_hash = "deadbeef"


def test_stage_result_is_frozen_and_evidence_is_not_shared():
    first = StageResult(TeardownStage.ROUTE, False)
    second = StageResult(TeardownStage.ROUTE, False)
    first.evidence["probe"] = "first"
    assert second.evidence == {}
    with pytest.raises(FrozenInstanceError):
        first.success = True


def test_stage_executor_signature_is_synchronous_and_exact():
    params = list(signature(StageExecutor.execute).parameters)
    assert params == ["self", "stage", "request"]
    assert list(signature(StageExecutor.verify).parameters) == ["self", "stage", "request"]


def test_exception_hierarchy_is_complete():
    assert issubclass(TeardownAuthorizationError, TeardownError)
    assert issubclass(TeardownSecurityError, TeardownError)
    assert issubclass(AttributionError, TeardownError)
    assert issubclass(DeadlineExceeded, TeardownError)
    assert issubclass(TeardownError, Exception)


def test_tailscale_attribution_contract_invariants():
    err = AttributionError("foreign node detected: unowned device")
    assert isinstance(err, TeardownError)
    assert "foreign node" in str(err)


def test_openbao_status_checks_contract_invariants():
    auth_err = TeardownAuthorizationError("openbao_authorization_failed")
    sec_err = TeardownSecurityError("OpenBao server error: HTTP 500")
    assert isinstance(auth_err, TeardownError)
    assert isinstance(sec_err, TeardownError)
