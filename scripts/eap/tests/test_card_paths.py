"""EAPR-P1-3: the EAP card generators must check referents, not names.

Run from the repository root:

    UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 \
        --with pytest python -m pytest scripts/eap/tests -q -p no:cacheprovider

Plain ``python3 -m pytest`` also works when the global libtmux plugin is not
loaded; the module imports no application code.
"""
from __future__ import annotations

import importlib.util
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

EAP_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = EAP_DIR.parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures"
VAULT_PROPOSALS = Path("/home/andy/Documents/Obsidian/v1/2. Areas/CEO/Innovation Proposals")

# The file 13c87855 overwrote. 183 lines at the integration base 844afa5a.
TENANT_ISOLATION = "d2-signalloom/apps/fe-signalloom/src/tests/test_tenant_isolation.py"

SPEC_GENERATORS = [
    "build_sled_specs.py", "build_sles_specs.py", "build_slet_specs.py", "build_slte_specs.py",
    "enrich_and_generate.py", "enrich_and_apply_slte.py", "generate_and_apply_slte.py",
    "generate_slea_specs.py", "generate_slea_specs_v2.py",
]
ALL_GENERATORS = SPEC_GENERATORS + ["apply_all_cards.py"]


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, str(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def cc():
    return _load("_card_contract", EAP_DIR / "_card_contract.py")


@pytest.fixture()
def tmp_repo(tmp_path: Path) -> Path:
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.email", "t@example.invalid"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.name", "t"], check=True)
    return tmp_path


# --- refuse_existing_target -------------------------------------------------

def test_negative_control_real_tenant_isolation_is_refused(cc):
    """The exact 13c87855 target: tracked, 183 lines, must refuse with the count."""
    with pytest.raises(SystemExit) as exc:
        cc.refuse_existing_target(REPO_ROOT, TENANT_ISOLATION)
    msg = str(exc.value)
    assert "target test file already exists" in msg
    assert TENANT_ISOLATION in msg
    assert "tracked" in msg
    assert re.search(r"\b183 lines\b", msg), msg


def test_positive_control_fresh_name_is_not_refused(cc):
    assert cc.refuse_existing_target(
        REPO_ROOT, "d2-signalloom/apps/fe-signalloom/src/tests/test_never_written_zz.py") is None


def test_tracked_but_deleted_from_disk_is_still_refused(cc, tmp_repo: Path):
    """The git call is load-bearing here: the file is in the index but gone from
    the working tree, which is what an agent that `rm`s then 'creates' sees.
    Removing the git call from the helper turns this red (mutation T1)."""
    target = tmp_repo / "tests" / "test_guard.py"
    target.parent.mkdir()
    target.write_text("\n".join(f"line {i}" for i in range(12)) + "\n")
    subprocess.run(["git", "-C", str(tmp_repo), "add", "tests/test_guard.py"], check=True)
    subprocess.run(["git", "-C", str(tmp_repo), "commit", "-q", "--no-gpg-sign", "-m", "fixture"], check=True)
    target.unlink()
    assert not target.exists()
    with pytest.raises(SystemExit) as exc:
        cc.refuse_existing_target(tmp_repo, "tests/test_guard.py")
    assert "tracked" in str(exc.value)
    assert "12 lines" in str(exc.value)


def test_untracked_existing_file_is_refused(cc, tmp_repo: Path):
    target = tmp_repo / "tests" / "test_untracked.py"
    target.parent.mkdir()
    target.write_text("a\nb\nc\n")
    with pytest.raises(SystemExit) as exc:
        cc.refuse_existing_target(tmp_repo, "tests/test_untracked.py")
    assert "untracked" in str(exc.value)
    assert "3 lines" in str(exc.value)


def test_allow_edit_marks_the_card_as_an_edit(cc):
    assert cc.refuse_existing_target(REPO_ROOT, TENANT_ISOLATION, allow_edit=True) is None


# --- check_card_targets / resolution ---------------------------------------

def test_short_form_deliverable_resolves_to_the_tracked_file(cc):
    spec = {"deliverables": ["Create tests/test_tenant_isolation.py with the sweep."]}
    with pytest.raises(SystemExit) as exc:
        cc.check_card_targets(REPO_ROOT, spec)
    assert TENANT_ISOLATION in str(exc.value)


def test_fe_signalloom_prefix_form_resolves(cc):
    spec = {"deliverables": ["fe-signalloom/src/tests/test_tenant_isolation.py with unit tests"]}
    with pytest.raises(SystemExit):
        cc.check_card_targets(REPO_ROOT, spec)


def test_edits_existing_declaration_lifts_the_refusal(cc):
    spec = {
        "deliverables": ["Extend tests/test_tenant_isolation.py with two more attacks."],
        "editsExisting": ["tests/test_tenant_isolation.py"],
    }
    checked = cc.check_card_targets(REPO_ROOT, spec)
    assert TENANT_ISOLATION in checked


def test_fresh_deliverable_passes_and_is_reported_free(cc):
    spec = {"deliverables": ["tests/test_brand_new_eap_thing.py asserting harness readiness"]}
    assert cc.check_card_targets(REPO_ROOT, spec) == []


# --- wire-spec headers ------------------------------------------------------

def test_wire_spec_constant_states_the_d1_doctrine(cc):
    text = cc.WIRE_SPEC_HEADERS
    assert "Authorization: Bearer <Dex JWT>" in text
    assert "SPIFFE SVID" in text
    assert "no identity header" in text
    assert cc.WIRE_SPEC["authorization"].startswith("Authorization: Bearer")


def test_apply_card_contract_carries_header_in_a_rendered_field_and_a_structured_one(cc):
    spec = {"approach": ["Step 1: do the thing."], "deliverables": []}
    out = cc.apply_card_contract(spec, repo_root=REPO_ROOT)
    assert out["wireSpec"]["authorization"].startswith("Authorization: Bearer")
    # kanban-check.sh renders `approach` as bullets near the top of the card;
    # an unrendered key would be lost in transcription exactly as D1 was.
    rendered = "\n".join(f"- {item}" for item in out["approach"])
    assert "Authorization: Bearer <Dex JWT>" in rendered
    assert out["approach"][0] == cc.WIRE_SPEC_HEADERS
    assert out["approach"][1] == "Step 1: do the thing."


def test_apply_card_contract_is_idempotent(cc):
    spec = {"approach": ["x"], "deliverables": []}
    cc.apply_card_contract(spec)
    cc.apply_card_contract(spec)
    assert spec["approach"].count(cc.WIRE_SPEC_HEADERS) == 1


def test_apply_card_contract_refuses_a_colliding_spec(cc):
    spec = {"approach": [], "deliverables": ["tests/test_tenant_isolation.py"]}
    with pytest.raises(SystemExit):
        cc.apply_card_contract(spec, repo_root=REPO_ROOT)


# --- the generators themselves ---------------------------------------------

def test_fixture_positive_control_mentions_the_vault_folder():
    """Positive control for the zero-match grep over scripts/eap/*.py."""
    hits = [p for p in FIXTURES.glob("*.md") if "Innovation Proposals" in p.read_text()]
    assert hits, "fixture must carry the folder name or the grep below is blind"


@pytest.mark.parametrize("name", ALL_GENERATORS)
def test_no_generator_reads_the_repo_docs_path(name):
    src = (EAP_DIR / name).read_text()
    assert "osramp-demo/docs/" not in src, name
    assert "docs/Proposal" not in src, name
    assert "Innovation Proposals" in src, name


@pytest.mark.parametrize("name", SPEC_GENERATORS)
def test_generator_is_wired_to_the_card_contract(name):
    src = (EAP_DIR / name).read_text()
    assert '"_card_contract.py"' in src, name
    assert re.search(r"cc\.apply_card_contract\((spec|card_spec), repo_root=cc\.REPO_ROOT\)", src), name


@pytest.mark.parametrize("name", SPEC_GENERATORS)
def test_generator_imports_cleanly_reads_the_vault_and_sets_no_bypass(name, monkeypatch):
    """Importing a generator must not run main(), must resolve PROPOSAL_PATH under
    the vault, and must not set KANBAN_BYPASS_GOV_WORKTREE at import time."""
    if not VAULT_PROPOSALS.is_dir():
        pytest.fail(f"vault not readable from this session: {VAULT_PROPOSALS}")
    monkeypatch.delenv("KANBAN_BYPASS_GOV_WORKTREE", raising=False)
    mod = _load(f"gen_{name[:-3]}", EAP_DIR / name)
    assert "KANBAN_BYPASS_GOV_WORKTREE" not in os.environ, name
    assert hasattr(mod, "cc") and hasattr(mod.cc, "apply_card_contract"), name
    proposal = getattr(mod, "PROPOSAL_PATH", None)
    if proposal is None:
        # generate_slea_specs.py resolves its path inside main(); check the source.
        src = (EAP_DIR / name).read_text()
        m = re.search(r'Path\("([^"]+Proposal — [^"]+\.md)"\)', src)
        assert m, name
        proposal = Path(m.group(1))
    assert Path(proposal).parent == VAULT_PROPOSALS, (name, proposal)
    assert Path(proposal).is_file(), (name, proposal)
