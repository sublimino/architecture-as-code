# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/tests/test_tenant_vector.py
# Zero-match gate and positive control assertions for pilot tenant migration
# ==============================================================================
import os
import re
from pathlib import Path
from unittest.mock import patch

import pytest

from environment_routing import (
    derive_customer_hash,
    get_eap_salt,
    _reset_eap_salt_cache,
)


def _find_repo_root() -> Path:
    # Walk up from this test file to repo root containing d2-signalloom, scripts, and .git
    curr = Path(__file__).resolve().parent
    while curr != curr.parent:
        if (curr / "d2-signalloom").is_dir() and (curr / "scripts").is_dir() and (curr / ".git").exists():
            return curr
        curr = curr.parent
    raise RuntimeError("Could not find repository root")


REPO_ROOT = _find_repo_root()

# Negative pattern for retired tenant typo and hardcoded hash (constructed dynamically)
_RETIRED_TOKENS = ["ku" + "rasi", "6f" + "82ad81"]
RETIRED_PATTERN = re.compile("|".join(re.escape(tok) for tok in _RETIRED_TOKENS), re.IGNORECASE)

# Webhook surface files explicitly excluded from migration (deleted in P3-4)
EXCLUDED_WEBHOOK_FILES = {
    "webhook_triggers.py",
    "test_webhook_triggers.py",
    f"test_{_RETIRED_TOKENS[0]}_webhook_lifecycle.py",
    "emit-eap-webhook.sh",
    "test_emit_eap_webhook.sh",
}

# Positive control pattern (shares NO constant with the negative probe)
POSITIVE_TOKEN = "kusari"
POSITIVE_PATTERN = re.compile(re.escape(POSITIVE_TOKEN), re.IGNORECASE)


def _walk_tracked_files():
    search_dirs = [
        REPO_ROOT / "d2-signalloom",
        REPO_ROOT / "scripts" / "eap",
    ]
    tracked_extensions = {".py", ".sh", ".yaml", ".yml", ".json", ".ts", ".js", ".md"}

    for base_dir in search_dirs:
        if not base_dir.exists():
            continue
        for root, dirs, files in os.walk(base_dir):
            # Skip caches, node_modules, build artifacts
            dirs[:] = [d for d in dirs if d not in {".cache", "node_modules", ".git", "__pycache__", ".pytest_cache"}]
            for fname in files:
                if fname in EXCLUDED_WEBHOOK_FILES:
                    continue
                file_path = Path(root) / fname
                if file_path.suffix in tracked_extensions:
                    yield file_path


def test_zero_match_retired_tenant_vector():
    """Gate: no tracked source or test file contains retired tenant tokens (except excluded webhook files)."""
    violations = []
    for fpath in _walk_tracked_files():
        try:
            content = fpath.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue
        for idx, line in enumerate(content.splitlines(), start=1):
            if RETIRED_PATTERN.search(line):
                rel_path = fpath.relative_to(REPO_ROOT)
                violations.append(f"{rel_path}:{idx}: {line.strip()}")

    assert not violations, f"Found retired tenant tokens in tracked files:\n" + "\n".join(violations)


def test_positive_control_pilot_tenant_presence():
    """Positive control: the same tree walker finds 'kusari' in at least three files."""
    matched_files = set()
    for fpath in _walk_tracked_files():
        try:
            content = fpath.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue
        if POSITIVE_PATTERN.search(content):
            matched_files.add(fpath.relative_to(REPO_ROOT))

    assert len(matched_files) >= 3, (
        f"Positive control failed: expected >= 3 files matching '{POSITIVE_TOKEN}', found {len(matched_files)}: {matched_files}"
    )


def test_canonical_hash_derivation_under_test_salt(monkeypatch):
    """derive_customer_hash('kusari') under the canonical test salt yields 'a0314bec'."""
    monkeypatch.setenv("SIGNAL_LOOM_EAP_SALT", "test-eap-salt-2026")
    _reset_eap_salt_cache()
    h = derive_customer_hash("kusari")
    assert h == "a0314bec"


def test_missing_salt_raises_runtime_error(monkeypatch):
    """get_eap_salt raises RuntimeError when neither env var nor OpenBao secret is available."""
    monkeypatch.delenv("SIGNAL_LOOM_EAP_SALT", raising=False)
    monkeypatch.delenv("BAO_ADDR", raising=False)
    monkeypatch.delenv("VAULT_ADDR", raising=False)
    _reset_eap_salt_cache()

    with patch("tenant_transit.OpenBaoTransitBackend", side_effect=Exception("OpenBao unavailable")):
        with pytest.raises(RuntimeError, match="EAP salt unavailable"):
            get_eap_salt()
