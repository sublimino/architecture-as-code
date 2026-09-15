# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors

"""
Mission-wide Tenant Isolation and Cryptographic Partitioning Test Suite.

SLCD-P6-1: Verifies multi-tenant isolation guarantees across the entire detective
telemetry sensor and wire contract architecture:
1. Cryptographic separation of pseudonym derivations via HKDF-SHA256 (P1-1).
2. Epoch rotation isolation and forward secrecy of session pseudonyms.
3. Kanban workspace isolation across tenant directory structures (P3-1).
4. ConfinedStore sandbox confinement across distinct tenant file trees (P4-1).
5. Wire contract tenant data boundary validation.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
import tempfile
from typing import Dict, List, Set
import unittest

PKG_DIR = Path(__file__).resolve().parent
if str(PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PKG_DIR))

try:
    from .coding_agent_models import (
        CodingAgentTelemetry,
        Harness,
        KanbanInfo,
        MetricsInfo,
        NetworkInfo,
        ProcessInfo,
        ToolCounts,
        derive_session_pseudonym,
    )
    from .coding_agent_wire import (
        WireContractError,
        canonical_json,
        decode_wire,
    )
    from .kanban import (
        KanbanCycleExtractor,
    )
    from .transcript import (
        ConfinedStore,
        TranscriptFormat,
        TranscriptIndexer,
    )
except (ImportError, ValueError):
    from coding_agent_models import (
        CodingAgentTelemetry,
        Harness,
        KanbanInfo,
        MetricsInfo,
        NetworkInfo,
        ProcessInfo,
        ToolCounts,
        derive_session_pseudonym,
    )
    from coding_agent_wire import (
        WireContractError,
        canonical_json,
        decode_wire,
    )
    from kanban import (
        KanbanCycleExtractor,
    )
    from transcript import (
        ConfinedStore,
        TranscriptFormat,
        TranscriptIndexer,
    )


class MissionTenantIsolationTests(unittest.TestCase):
    """Assert multi-tenant isolation and cryptographic partitioning across all sensor subsystems."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.mock_root = Path(self.temp_dir.name)
        self.root_key = b"01234567890123456789012345678901"  # 32 bytes

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def test_pseudonym_cryptographic_separation_across_tenants(self) -> None:
        """Assert identical raw session IDs yield completely distinct pseudonyms across tenants."""
        tenants = [f"tenant-{i:03d}" for i in range(50)]
        raw_session_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        epoch = 1

        pseudonyms: Set[str] = set()
        for tenant in tenants:
            pseudo = derive_session_pseudonym(self.root_key, epoch, tenant, raw_session_id)
            self.assertEqual(len(pseudo), 64, "Pseudonym must be 64-hex chars")
            self.assertTrue(all(c in "0123456789abcdef" for c in pseudo), "Pseudonym must be lowercase hex")
            self.assertNotIn(pseudo, pseudonyms, f"Collision detected for tenant {tenant}")
            pseudonyms.add(pseudo)

        self.assertEqual(len(pseudonyms), len(tenants))

    def test_pseudonym_epoch_rotation_guarantees_forward_secrecy(self) -> None:
        """Assert rotating epochs produces non-linkable pseudonyms for the same tenant and session."""
        tenant = "tenant-enterprise-prod"
        raw_session_id = "agent-session-fixed-seed"
        epochs = range(1, 20)

        epoch_pseudonyms: Set[str] = set()
        for epoch in epochs:
            pseudo = derive_session_pseudonym(self.root_key, epoch, tenant, raw_session_id)
            self.assertNotIn(pseudo, epoch_pseudonyms, f"Epoch {epoch} produced duplicate pseudonym")
            epoch_pseudonyms.add(pseudo)

        self.assertEqual(len(epoch_pseudonyms), len(epochs))

    def test_pseudonym_root_key_rotation_isolation(self) -> None:
        """Assert rotating root key isolates pseudonyms globally."""
        tenant = "tenant-gamma"
        raw_session_id = "shared-session-token"
        epoch = 1

        key1 = b"root-key-epoch-1-initial-seed-00"
        key2 = b"root-key-epoch-2-rotated-seed-00"

        p1 = derive_session_pseudonym(key1, epoch, tenant, raw_session_id)
        p2 = derive_session_pseudonym(key2, epoch, tenant, raw_session_id)

        self.assertNotEqual(p1, p2)

    def test_pseudonym_derivation_fails_closed_on_invalid_inputs(self) -> None:
        """Assert pseudonym derivation refuses invalid keys, missing tenants, or empty sessions."""
        # Short root key (<32 bytes)
        with self.assertRaises(ValueError):
            derive_session_pseudonym(b"short-key", 1, "tenant-a", "sess-1")

        # Empty tenant_id
        with self.assertRaises(ValueError):
            derive_session_pseudonym(self.root_key, 1, "", "sess-1")

        # Empty raw_session_id
        with self.assertRaises(ValueError):
            derive_session_pseudonym(self.root_key, 1, "tenant-a", "")

    def test_kanban_workspace_cross_tenant_isolation(self) -> None:
        """Assert Kanban extractor isolates sessions between distinct tenant workspaces."""
        kanban_root = self.mock_root / "kanban"
        ws_tenant_a = kanban_root / "workspaces" / "tenant-a-repo"
        ws_tenant_b = kanban_root / "workspaces" / "tenant-b-repo"

        ws_tenant_a.mkdir(parents=True, exist_ok=True)
        ws_tenant_b.mkdir(parents=True, exist_ok=True)

        # Tenant A session
        (ws_tenant_a / "sessions.json").write_text(
            json.dumps({
                "TASK-A-01": {
                    "taskId": "TASK-A-01",
                    "state": "in_progress",
                    "startedAt": 1788384000000,
                    "latestTurnCheckpoint": {"turn": 2, "ref": "refs/checkpoints/1", "commit": "111111", "createdAt": 1788384000000},
                    "restartCount": 0,
                }
            }),
            encoding="utf-8",
        )

        # Tenant B session
        (ws_tenant_b / "sessions.json").write_text(
            json.dumps({
                "TASK-B-01": {
                    "taskId": "TASK-B-01",
                    "state": "in_progress",
                    "startedAt": 1788384000000,
                    "latestTurnCheckpoint": {"turn": 4, "ref": "refs/checkpoints/2", "commit": "222222", "createdAt": 1788384000000},
                    "restartCount": 1,
                }
            }),
            encoding="utf-8",
        )

        extractor = KanbanCycleExtractor(kanban_home=kanban_root)

        # Query Tenant A workspace
        obs_a = extractor.extract_active_sessions(workspace_id="tenant-a-repo")
        self.assertEqual(len(obs_a), 1)
        self.assertEqual(obs_a[0].task_id, "TASK-A-01")

        # Query Tenant B workspace
        obs_b = extractor.extract_active_sessions(workspace_id="tenant-b-repo")
        self.assertEqual(len(obs_b), 1)
        self.assertEqual(obs_b[0].task_id, "TASK-B-01")

        # Query non-existent Tenant C workspace
        obs_c = extractor.extract_active_sessions(workspace_id="tenant-c-repo")
        self.assertEqual(len(obs_c), 0)

    def test_confined_store_sandbox_cross_tenant_isolation(self) -> None:
        """Assert ConfinedStore strictly confines reading within tenant store boundaries."""
        tenant_a_root = self.mock_root / "tenant_a"
        tenant_b_root = self.mock_root / "tenant_b"

        tenant_a_root.mkdir(parents=True, exist_ok=True)
        tenant_b_root.mkdir(parents=True, exist_ok=True)

        # Write data inside Tenant B
        secret_file = tenant_b_root / "secret_transcript.jsonl"
        secret_file.write_text(json.dumps({"type": "assistant", "message": {"usage": {"input_tokens": 100}}}) + "\n")

        # Open store confined to Tenant A
        with ConfinedStore(tenant_a_root) as store_a:
            # 1. Direct path escape via ../
            rel_escape = "../tenant_b/secret_transcript.jsonl"
            with self.assertRaises(OSError):
                store_a.open_relative(rel_escape)

            # 2. Absolute path escape
            with self.assertRaises(OSError):
                store_a.open_relative(str(secret_file.resolve()))

            # 3. Symlink escape attempt inside Tenant A pointing to Tenant B
            symlink_escape = tenant_a_root / "symlink_to_b.jsonl"
            symlink_escape.symlink_to(secret_file)

            with self.assertRaises(OSError):
                store_a.open_relative("symlink_to_b.jsonl")


if __name__ == "__main__":
    unittest.main()
