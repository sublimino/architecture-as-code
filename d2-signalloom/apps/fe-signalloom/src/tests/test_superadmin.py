"""Exercise the server-side superadmin gate against validated token identities.

These tests exist because the dashboard's superadmin affordance is only a
visibility hint, while the real risk is an authenticated caller trying to
smuggle privilege through browser-controlled state. The suite therefore proves
that the server-side predicate reads only the validated ``Principal`` identity,
normalises email claims deliberately, preserves exact subject matching, and
fails closed when no configured allowlist admits the caller.
"""
from __future__ import annotations

from types import SimpleNamespace

import pytest

import superadmin
from api_compat import APIError, Principal


@pytest.fixture
def configured_settings(monkeypatch: pytest.MonkeyPatch) -> SimpleNamespace:
    fake_settings = SimpleNamespace(
        api_superadmin_emails={"demo-user@signalloom.local"},
        api_superadmin_subjects={"demo-user"},
    )
    monkeypatch.setattr(superadmin, "settings", fake_settings)
    return fake_settings


def _principal(*, subject: str = "subject", email: str | None = "user@example.test") -> Principal:
    return Principal(tenant="tenant-demo", subject=subject, email=email)


def test_is_superadmin_matches_email_allowlist(configured_settings: SimpleNamespace) -> None:
    principal = _principal(subject="ordinary-user", email="demo-user@signalloom.local")

    assert superadmin.is_superadmin(principal) is True


@pytest.mark.parametrize(
    "email",
    [
        "DEMO-USER@SIGNALLOOM.LOCAL",
        "  demo-user@signalloom.local  ",
    ],
)
def test_is_superadmin_normalizes_email_case_and_whitespace(
    configured_settings: SimpleNamespace,
    email: str,
) -> None:
    principal = _principal(subject="ordinary-user", email=email)

    assert superadmin.is_superadmin(principal) is True


def test_is_superadmin_matches_subject_allowlist(configured_settings: SimpleNamespace) -> None:
    principal = _principal(subject="demo-user", email="other@example.test")

    assert superadmin.is_superadmin(principal) is True


def test_is_superadmin_falls_through_from_missing_email_to_subject_match(
    configured_settings: SimpleNamespace,
) -> None:
    principal = _principal(subject="demo-user", email=None)

    assert superadmin.is_superadmin(principal) is True


def test_is_superadmin_denies_missing_email_without_subject_match(
    configured_settings: SimpleNamespace,
) -> None:
    principal = _principal(subject="ordinary-user", email=None)

    assert superadmin.is_superadmin(principal) is False


def test_is_superadmin_denies_when_both_allowlists_are_empty(
    configured_settings: SimpleNamespace,
) -> None:
    configured_settings.api_superadmin_emails = set()
    configured_settings.api_superadmin_subjects = set()

    assert superadmin.is_superadmin(_principal(subject="demo-user", email="demo-user@signalloom.local")) is False


def test_is_superadmin_denies_non_matching_principal(configured_settings: SimpleNamespace) -> None:
    principal = _principal(subject="ordinary-user", email="ordinary@example.test")

    assert superadmin.is_superadmin(principal) is False


def test_is_superadmin_uses_documented_defaults_when_settings_omit_allowlists(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(superadmin, "settings", SimpleNamespace())

    assert superadmin.is_superadmin(
        _principal(subject="demo-user", email="DEMO-USER@SIGNALLOOM.LOCAL"),
    ) is True


def test_require_superadmin_returns_principal_for_authorized_caller(
    configured_settings: SimpleNamespace,
) -> None:
    principal = _principal(subject="ordinary-user", email="demo-user@signalloom.local")

    assert superadmin.require_superadmin(principal) is principal


def test_require_superadmin_raises_typed_403_for_non_superadmin(
    configured_settings: SimpleNamespace,
) -> None:
    principal = _principal(subject="ordinary-user", email="ordinary@example.test")

    with pytest.raises(APIError) as exc_info:
        superadmin.require_superadmin(principal)

    assert exc_info.value.status_code == 403
    assert exc_info.value.code == "superadmin_required"
    assert exc_info.value.message == "Superadmin access is required"
