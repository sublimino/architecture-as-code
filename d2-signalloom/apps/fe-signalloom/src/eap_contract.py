"""EAP contract definitions, trust domain configuration, and shared constants."""
from __future__ import annotations

import os

SPIFFE_TRUST_DOMAIN = os.environ.get("SIGNAL_LOOM_TRUST_DOMAIN", "signalloom.demo")
OPENBAO_PORT = 8200
SPIRE_SERVER_PORT = 8081


def get_spiffe_trust_domain() -> str:
    """Trust domain for tenant SPIFFE IDs.

    Defaults to ``signalloom.demo``. Overridable through
    ``SIGNAL_LOOM_TRUST_DOMAIN`` (or legacy ``SLET_SPIFFE_TRUST_DOMAIN``).
    """
    return os.environ.get(
        "SIGNAL_LOOM_TRUST_DOMAIN",
        os.environ.get("SLET_SPIFFE_TRUST_DOMAIN", SPIFFE_TRUST_DOMAIN),
    )
