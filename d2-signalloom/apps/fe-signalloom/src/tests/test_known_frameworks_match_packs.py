"""The fallback framework catalogue agrees with the policy packs in the repo.

``routers.compliance.KNOWN_FRAMEWORKS`` is served when the policy engine is
unreachable.  The fe image does not carry ``policy/`` (the Dockerfile copies
``src/`` only), so the catalogue cannot be derived at runtime; this test is the
derivation, run against the packs in the checkout.

``version`` is the newest pack version and ``controls_count`` the number of
checks in it: every check is one assessable governance control here (the seed
maps each check to one ``governance_controls`` row; FINOS AIGF's 16 checks are
16 seeded controls, under 13 pack-level control headings).
"""
from __future__ import annotations

import json
from pathlib import Path

from routers.compliance import KNOWN_FRAMEWORKS

PACKS = Path(__file__).resolve().parents[5] / "policy" / "frameworks"


def _semver(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.lstrip("v").split("."))


def _newest_pack(pack_id: str) -> dict:
    packs = [json.loads(p.read_text(encoding="utf-8")) for p in (PACKS / pack_id).glob("*/framework.json")]
    return max(packs, key=lambda pack: _semver(pack["version"]))


def _check_count(pack: dict) -> int:
    return sum(len(control["checks"]) for cs in pack["controlSets"] for control in cs["controls"])


def test_the_pack_directory_is_where_the_test_thinks_it_is():
    # A moved tree must fail here, not silently compare nothing.
    assert (PACKS / "CONFORMANCE.md").is_file(), PACKS


def test_every_catalogue_entry_with_a_pack_matches_its_newest_version_and_check_count():
    mismatches = []
    for framework_id, entry in KNOWN_FRAMEWORKS.items():
        if not (PACKS / framework_id).is_dir():
            continue
        pack = _newest_pack(framework_id)
        want = {"version": pack["version"], "controls_count": _check_count(pack)}
        got = {"version": entry["version"], "controls_count": entry["controls_count"]}
        if got != want:
            mismatches.append((framework_id, got, want))
    assert mismatches == []


def test_only_soc2_is_listed_without_a_pack():
    assert sorted(f for f in KNOWN_FRAMEWORKS if not (PACKS / f).is_dir()) == ["soc-2"]
