"""RFC 6962 Merkle tree hashing -- the same construction Rekor and CT use.

We could have digested the window with a flat SHA256 over the concatenated
rows, and for the pass/fail answer that would be enough.  The tree earns its
place for one reason: it produces inclusion proofs.  When the row-level chaining
work lands it will need to point at a specific row and say "this row, this
position, this checkpoint" without shipping the whole window, and a flat hash
cannot do that.

The tests below deliberately avoid asserting memorised hex constants for the
general case.  A "known vector" that is actually a misremembered constant is
worse than no vector: it fails against a correct implementation and sends the
next person hunting a bug that is not there.  Instead the recurrence is pinned
by construction, in terms the RFC states directly, and the published CT vectors
are checked separately at the bottom where a mismatch is unambiguous.
"""
import hashlib

import pytest

from audit_anchor.merkle import (
    empty_root,
    inclusion_proof,
    leaf_hashes_root,
    verify_inclusion_proof,
)


def _leaf(b: bytes) -> bytes:
    return hashlib.sha256(b"\x00" + b).digest()


def _node(left: bytes, right: bytes) -> bytes:
    return hashlib.sha256(b"\x01" + left + right).digest()


# Deliberately varied lengths, matching the shape of the RFC 6962 test inputs.
INPUTS = [
    b"",
    bytes.fromhex("00"),
    bytes.fromhex("10"),
    bytes.fromhex("2021"),
    bytes.fromhex("3031"),
    bytes.fromhex("40414243"),
    bytes.fromhex("5051525354555657"),
    bytes.fromhex("606162636465666768696a6b6c6d6e6f"),
]
LEAVES = [_leaf(b) for b in INPUTS]


# ══════════════════════════════════════════════════════════════════════════════
# The recurrence, stated the way RFC 6962 section 2.1 states it
# ══════════════════════════════════════════════════════════════════════════════


def test_empty_tree_is_the_hash_of_the_empty_string():
    assert empty_root() == hashlib.sha256(b"").digest()
    assert leaf_hashes_root([]) == hashlib.sha256(b"").digest()


def test_single_leaf_tree_is_the_leaf_itself():
    assert leaf_hashes_root(LEAVES[:1]) == LEAVES[0]


def test_two_leaf_tree():
    assert leaf_hashes_root(LEAVES[:2]) == _node(LEAVES[0], LEAVES[1])


def test_three_leaf_tree_splits_at_two():
    left = _node(LEAVES[0], LEAVES[1])
    assert leaf_hashes_root(LEAVES[:3]) == _node(left, LEAVES[2])


def test_five_leaf_tree_splits_at_four_not_at_the_midpoint():
    """This is the test that distinguishes RFC 6962 from a naive tree.

    RFC 6962 splits at the largest power of two strictly less than n, so five
    leaves split 4+1.  A ceil(n/2) split would give 3+2 and produce a different
    root.  Both are perfectly good Merkle trees; only one of them interoperates
    with Rekor, CT, and every other transparency log, which is the entire point
    of choosing an existing construction over inventing one.
    """
    left = _node(_node(LEAVES[0], LEAVES[1]), _node(LEAVES[2], LEAVES[3]))
    assert leaf_hashes_root(LEAVES[:5]) == _node(left, LEAVES[4])


def test_six_leaf_tree_splits_four_two():
    left = _node(_node(LEAVES[0], LEAVES[1]), _node(LEAVES[2], LEAVES[3]))
    right = _node(LEAVES[4], LEAVES[5])
    assert leaf_hashes_root(LEAVES[:6]) == _node(left, right)


def test_seven_leaf_tree():
    left = _node(_node(LEAVES[0], LEAVES[1]), _node(LEAVES[2], LEAVES[3]))
    right = _node(_node(LEAVES[4], LEAVES[5]), LEAVES[6])
    assert leaf_hashes_root(LEAVES[:7]) == _node(left, right)


# ══════════════════════════════════════════════════════════════════════════════
# Properties that matter for tamper detection
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.parametrize("n", range(1, 9))
def test_changing_any_leaf_changes_the_root(n):
    baseline = leaf_hashes_root(LEAVES[:n])
    for i in range(n):
        mutated = list(LEAVES[:n])
        mutated[i] = _leaf(b"tampered")
        assert leaf_hashes_root(mutated) != baseline, f"leaf {i} of {n} did not move the root"


@pytest.mark.parametrize("n", range(2, 9))
def test_reordering_leaves_changes_the_root(n):
    """Order is part of the commitment. Rows are sorted by (timestamp, id)
    before hashing, so a reordering means the sort input changed."""
    swapped = list(LEAVES[:n])
    swapped[0], swapped[1] = swapped[1], swapped[0]
    assert leaf_hashes_root(swapped) != leaf_hashes_root(LEAVES[:n])


@pytest.mark.parametrize("n", range(1, 9))
def test_removing_a_leaf_changes_the_root(n):
    """Deletion is the attack this control exists to catch."""
    for i in range(n):
        pruned = LEAVES[:n][:i] + LEAVES[:n][i + 1 :]
        assert leaf_hashes_root(pruned) != leaf_hashes_root(LEAVES[:n])


def test_leaf_and_node_prefixes_are_distinct():
    """Without domain separation an internal node could be presented as a leaf,
    and a tree over n leaves could be forged as a tree over fewer."""
    forged = hashlib.sha256(b"\x01" + LEAVES[0] + LEAVES[1]).digest()
    honest = hashlib.sha256(b"\x00" + LEAVES[0] + LEAVES[1]).digest()
    assert forged != honest


# ══════════════════════════════════════════════════════════════════════════════
# Inclusion proofs -- what the row-chaining work will consume
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.parametrize("n", range(1, 9))
def test_inclusion_proof_round_trips_for_every_index(n):
    root = leaf_hashes_root(LEAVES[:n])
    for i in range(n):
        proof = inclusion_proof(LEAVES[:n], i)
        assert verify_inclusion_proof(LEAVES[i], i, n, proof, root), f"index {i} of {n}"


@pytest.mark.parametrize("n", range(2, 9))
def test_inclusion_proof_rejects_the_wrong_leaf(n):
    root = leaf_hashes_root(LEAVES[:n])
    proof = inclusion_proof(LEAVES[:n], 0)
    assert not verify_inclusion_proof(_leaf(b"not-in-tree"), 0, n, proof, root)


@pytest.mark.parametrize("n", range(2, 9))
def test_inclusion_proof_rejects_the_wrong_position(n):
    root = leaf_hashes_root(LEAVES[:n])
    proof = inclusion_proof(LEAVES[:n], 0)
    assert not verify_inclusion_proof(LEAVES[0], 1, n, proof, root)


def test_inclusion_proof_index_is_bounds_checked():
    with pytest.raises(IndexError):
        inclusion_proof(LEAVES[:4], 4)


def test_single_leaf_proof_is_empty():
    assert inclusion_proof(LEAVES[:1], 0) == []


# ══════════════════════════════════════════════════════════════════════════════
# Interoperability with the published RFC 6962 / Certificate Transparency vectors
# ══════════════════════════════════════════════════════════════════════════════

# From the Certificate Transparency reference implementation's Merkle tree test
# vectors, computed over the eight INPUTS above.  These are the check that we
# have implemented the RFC rather than a plausible tree of our own: they were
# produced by a different codebase entirely.
CT_ROOTS = {
    0: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    1: "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d",
    2: "fac54203e7cc696cf0dfcb42c92a1d9dbaf70ad9e621f4bd8d98662f00e3c125",
    3: "aeb6bcfe274b70a14fb067a5e5578264db0fa9b51af5e0ba159158f329e06e77",
    4: "d37ee418976dd95753c1c73862b9398fa2a2cf9b4ff0fdfe8b30cd95209614b7",
    5: "4e3bbb1f7b478dcfe71fb631631519a3bca12c9aefca1612bfce4c13a86264d4",
    6: "76e67dadbcdf1e10e1b74ddc608abd2f98dfb16fbce75277b5232a127f2087ef",
    7: "ddb89be403809e325750d3d263cd78929c2942b7942a34b77e122c9594a74c8c",
    8: "5dc9da79a70659a9ad559cb701ded9a2ab9d823aad2f4960cfe370eff4604328",
}


@pytest.mark.parametrize("n", sorted(CT_ROOTS))
def test_matches_published_certificate_transparency_roots(n):
    assert leaf_hashes_root(LEAVES[:n]).hex() == CT_ROOTS[n]
