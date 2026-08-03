"""Keep privileged demo controls behind a server-side identity check.

This module exists because the dashboard's client-side superadmin flag is only
for visibility, while the SuperCred demo's mutating routes change shared
cluster state. The threat model is an authenticated caller trying to escalate
through browser-controlled request fields or frontend state, so the server
decides superadmin access only from the validated JWT-derived ``Principal``
identity and never from headers, query parameters, or request bodies the
client can author.
"""
from __future__ import annotations

from typing import Annotated

from fastapi import Depends

from api_compat import APIError, Principal, authenticated_principal
from config import settings

_DEFAULT_SUPERADMIN_EMAILS = frozenset({"demo-user@signalloom.local"})
_DEFAULT_SUPERADMIN_SUBJECTS = frozenset({"demo-user"})


def _configured_strings(value: object, *, setting_name: str) -> set[str]:
    if isinstance(value, str):
        raise TypeError(f"{setting_name} must be an iterable of strings, not a single string")
    try:
        candidates = iter(value)
    except TypeError as exc:
        raise TypeError(f"{setting_name} must be an iterable of strings") from exc

    configured: set[str] = set()
    for candidate in candidates:
        if not isinstance(candidate, str):
            raise TypeError(f"{setting_name} must contain only strings")
        configured.add(candidate)
    return configured


def _configured_superadmin_emails() -> set[str]:
    configured = getattr(settings, "api_superadmin_emails", _DEFAULT_SUPERADMIN_EMAILS)
    return {_normalize_email(email) for email in _configured_strings(configured, setting_name="api_superadmin_emails")}


def _configured_superadmin_subjects() -> set[str]:
    configured = getattr(settings, "api_superadmin_subjects", _DEFAULT_SUPERADMIN_SUBJECTS)
    return _configured_strings(configured, setting_name="api_superadmin_subjects")


def _normalize_email(email: str) -> str:
    # Email claims are compared case-insensitively in practice, and Dex can
    # hand back padded strings, so both sides are stripped and lowercased.
    return email.strip().lower()


def is_superadmin(principal: Principal) -> bool:
    email_allowlist = _configured_superadmin_emails()
    subject_allowlist = _configured_superadmin_subjects()

    if principal.email is not None and _normalize_email(principal.email) in email_allowlist:
        return True

    # ``sub`` is an opaque identifier, so the comparison stays exact rather
    # than case-folding or trimming something security-sensitive.
    return principal.subject in subject_allowlist


def require_superadmin(
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> Principal:
    if not is_superadmin(principal):
        raise APIError(
            403,
            "superadmin_required",
            "Superadmin access is required",
        )
    return principal
