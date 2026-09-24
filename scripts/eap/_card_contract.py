#!/usr/bin/env python3
"""Shared contract helpers for the EAP card generators (EAPR-P1-3).

Two defects this module closes, both recorded in the EAPR decision log:

1. A generated card could name a deliverable test file that already existed in
   the tree. Commit 13c87855 overwrote 1,935 lines of
   ``test_tenant_isolation.py`` because nothing asked git. A regex over the
   deliverable string checks the *name*; this module checks the *referent* —
   ``git ls-files`` for tracked files and ``Path.exists`` for untracked ones —
   and refuses generation with the existing file's line count in the message.

2. The proposal's ``Authorization: Bearer`` wire spec was lost in transcription:
   the generators carried nothing of it, so the controller wrote routers
   without auth. ``apply_card_contract`` carries the wire spec twice — as a
   structured ``wireSpec`` field for the prompt-contract validator to gate on,
   and as the first ``approach`` bullet, because ``kanban-check.sh`` renders
   only enumerated spec keys into the card body and an unrendered field would
   be lost exactly the way the original was.

Every ``build_*_specs.py`` / ``generate_*_specs*.py`` / ``enrich_*.py``
generator calls ``apply_card_contract(spec, repo_root=REPO_ROOT)`` immediately
before writing a spec file. Tests: ``scripts/eap/tests/test_card_paths.py``.
"""
from __future__ import annotations

import re
import subprocess
from pathlib import Path

# scripts/eap/_card_contract.py -> repository root, independent of cwd and of
# which checkout (worktree or principal) the generator is run from.
REPO_ROOT = Path(__file__).resolve().parents[2]

# Proposal — Signal Loom EAP Certification Remediation (2026-Q3), D1 row and
# SP-5. Humans, systems and the sensor authenticate with a Dex JWT; agents with
# a SPIFFE SVID; there is no identity header of any kind.
WIRE_SPEC = {
    "authorization": "Authorization: Bearer <Dex JWT> for humans and systems; "
                     "SPIFFE SVID (supercredential) for agents",
    "identityHeader": "none — X-SPIFFE-ID and any client-supplied identity or "
                      "tenant header are never read",
    "tenantSource": "derived from the authenticated principal "
                    "(authenticated_tenant), never from a path segment or header",
    "enforcement": "router-level dependencies=[Depends(api_compat."
                   "authenticated_principal)] at every install_*_api include_router",
    "source": "Proposal — Signal Loom EAP Certification Remediation (2026-Q3), "
              "D1 / SP-5",
}

WIRE_SPEC_HEADERS = (
    "Wire spec (proposal D1, non-negotiable for any router or route this card "
    "touches): every EAP route requires an authenticated principal. Humans and "
    "systems present `Authorization: Bearer <Dex JWT>`; agents present a SPIFFE "
    "SVID; there is no identity header — `X-SPIFFE-ID` and any client-supplied "
    "identity or tenant header are never read. Tenant is derived from the "
    "authenticated principal only, never from a path segment or header. Enforce "
    "at router level with `dependencies=[Depends(api_compat.authenticated_"
    "principal)]` on every `include_router`."
)

# Deliverable strings are prose. These are the shapes the survey of all ten
# generators found for a test file: `tests/test_x.py`,
# `fe-signalloom/src/tests/test_x.py`, and the full repository-relative path.
TEST_FILE_RE = re.compile(
    r"(?<![A-Za-z0-9_])((?:[A-Za-z0-9_.-]+/)*tests?/test_[A-Za-z0-9_]+\.(?:py|sh|bats))"
)

# Roots a short-form path is resolved against, in order. The repository root
# first, then the two prefixes the generators actually use.
SEARCH_ROOTS = ("", "d2-signalloom/apps", "d2-signalloom/apps/fe-signalloom/src")


def _git(repo_root: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", str(repo_root), *args],
        capture_output=True, text=True, check=False,
    )


def is_tracked(repo_root: Path | str, rel_path: str) -> bool:
    """True when git's index knows ``rel_path`` — tracked even if deleted on disk."""
    return _git(Path(repo_root), "ls-files", "--error-unmatch", "--", rel_path).returncode == 0


def _line_count(repo_root: Path, rel_path: str, tracked: bool) -> int:
    disk = Path(repo_root, rel_path)
    if disk.is_file():
        with disk.open("rb") as fh:
            return sum(1 for _ in fh)
    if tracked:
        # Tracked but absent from the working tree: count the indexed blob so
        # the refusal still says how much would be lost.
        res = _git(repo_root, "show", f":{rel_path}")
        if res.returncode == 0:
            return res.stdout.count("\n")
    return 0


def refuse_existing_target(repo_root: Path | str, rel_path: str, *, allow_edit: bool = False) -> None:
    """Raise ``SystemExit`` when ``rel_path`` already exists in the repository.

    Existence is decided by the tree, not the name: ``git ls-files`` answers for
    tracked files (including ones deleted from the working tree) and
    ``Path.exists`` for untracked ones. ``allow_edit=True`` marks the card as an
    edit of the existing file and turns the refusal off for that path.
    """
    repo_root = Path(repo_root)
    rel_path = str(rel_path).lstrip("./")
    tracked = is_tracked(repo_root, rel_path)
    on_disk = Path(repo_root, rel_path).exists()
    if not (tracked or on_disk):
        return None
    if allow_edit:
        return None
    lines = _line_count(repo_root, rel_path, tracked)
    state = "tracked" if tracked else "untracked"
    raise SystemExit(
        f"target test file already exists: {rel_path} ({state}, {lines} lines); "
        "choose a new filename or mark the card as an edit of the existing file "
        "(list it under the spec's `editsExisting`)"
    )


def resolve_candidates(repo_root: Path | str, token: str) -> list[str]:
    """Map a deliverable's test-file token to the repository paths it could mean.

    Direct hits under each search root come first; when none exists, any
    tracked file sharing the basename under a ``tests/`` directory is returned,
    because that is precisely the same-named collision 13c87855 was.
    """
    repo_root = Path(repo_root)
    token = token.lstrip("./")
    hits: list[str] = []
    for root in SEARCH_ROOTS:
        rel = f"{root}/{token}" if root else token
        if is_tracked(repo_root, rel) or Path(repo_root, rel).exists():
            hits.append(rel)
    if hits:
        return hits
    base = Path(token).name
    res = _git(repo_root, "ls-files", "--", f"*/tests/{base}", f"*/test/{base}", f"tests/{base}")
    return [line for line in res.stdout.splitlines() if line.strip()]


def extract_test_targets(spec: dict) -> list[str]:
    """Test-file tokens named by a spec's deliverables, de-duplicated in order."""
    seen: dict[str, None] = {}
    for item in spec.get("deliverables") or []:
        for match in TEST_FILE_RE.findall(str(item)):
            seen.setdefault(match, None)
    return list(seen)


def check_card_targets(repo_root: Path | str, spec: dict) -> list[str]:
    """Refuse the spec when any deliverable test file already exists.

    Returns the repository-relative paths that were checked and found free (or
    declared as edits). Raises ``SystemExit`` on the first collision.
    """
    repo_root = Path(repo_root)
    edits = {str(p).lstrip("./") for p in (spec.get("editsExisting") or [])}
    edit_basenames = {Path(p).name for p in edits}
    checked: list[str] = []
    for token in extract_test_targets(spec):
        for rel in resolve_candidates(repo_root, token):
            allow = rel in edits or Path(rel).name in edit_basenames
            refuse_existing_target(repo_root, rel, allow_edit=allow)
            checked.append(rel)
    return checked


def apply_card_contract(spec: dict, *, repo_root: Path | str | None = None) -> dict:
    """Finalise a card spec: collision check, then carry the wire-spec headers.

    Idempotent — calling it twice neither duplicates the approach bullet nor
    re-checks differently.
    """
    if repo_root is not None:
        check_card_targets(repo_root, spec)
    spec["wireSpec"] = dict(WIRE_SPEC)
    approach = spec.get("approach")
    if isinstance(approach, list):
        if WIRE_SPEC_HEADERS not in approach:
            approach.insert(0, WIRE_SPEC_HEADERS)
    elif isinstance(approach, str):
        if WIRE_SPEC_HEADERS not in approach:
            spec["approach"] = WIRE_SPEC_HEADERS + "\n" + approach
    else:
        spec["approach"] = [WIRE_SPEC_HEADERS]
    return spec
