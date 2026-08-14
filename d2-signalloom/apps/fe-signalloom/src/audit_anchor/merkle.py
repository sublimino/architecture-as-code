"""RFC 6962 Merkle tree hashing.

The same construction Certificate Transparency and Rekor use.  Choosing an
existing transparency-log tree over inventing one is not aesthetics: it means an
auditor can verify a checkpoint with any off-the-shelf CT tooling, and it means
the inclusion proofs we emit are the shape every other log emits.

    MTH({})     = SHA256()
    MTH({d0})   = SHA256(0x00 || d0)
    MTH(D[n])   = SHA256(0x01 || MTH(D[0:k]) || MTH(D[k:n]))
                  where k is the largest power of two STRICTLY LESS than n

That last clause is the whole subtlety.  A ceil(n/2) split produces a perfectly
good Merkle tree that is not this one -- for five leaves the RFC splits 4+1
while a midpoint split gives 3+2 -- and the two disagree on the root for every
tree size that is not a power of two.

A flat SHA256 over the concatenated rows would answer the pass/fail question
just as well.  The tree earns its place because it produces inclusion proofs:
when the row-level chaining work lands it will need to point at one row and say
"this row, this position, this checkpoint" without shipping the whole window,
and a flat hash cannot do that.
"""
import hashlib

_LEAF_PREFIX = b"\x00"
_NODE_PREFIX = b"\x01"


def empty_root() -> bytes:
    """RFC 6962: the empty tree hashes to SHA256 of the empty string.

    Quiet windows are normal -- a demo cluster overnight produces none -- and
    they must still yield a checkpoint, because a skipped checkpoint is
    indistinguishable from a deleted one.
    """
    return hashlib.sha256(b"").digest()


def node_hash(left: bytes, right: bytes) -> bytes:
    """SHA256(0x01 || left || right).

    The 0x01 prefix is domain separation against the 0x00 of a leaf. Without
    it, an internal node could be presented as a leaf and a tree over n leaves
    forged as a tree over fewer -- the standard second-preimage attack on
    unprefixed Merkle trees.
    """
    return hashlib.sha256(_NODE_PREFIX + left + right).digest()


def leaf_hash(record: bytes) -> bytes:
    """SHA256(0x00 || record). Mirrors canonical.leaf_hash."""
    return hashlib.sha256(_LEAF_PREFIX + record).digest()


def _split_point(n: int) -> int:
    """Largest power of two strictly less than n, for n >= 2."""
    return 1 << ((n - 1).bit_length() - 1)


def leaf_hashes_root(leaves: list) -> bytes:
    """Merkle tree hash over already-computed leaf hashes."""
    n = len(leaves)
    if n == 0:
        return empty_root()
    if n == 1:
        return leaves[0]
    k = _split_point(n)
    return node_hash(leaf_hashes_root(leaves[:k]), leaf_hashes_root(leaves[k:]))


def inclusion_proof(leaves: list, index: int) -> list:
    """RFC 6962 PATH(index, leaves): the audit path, ordered leaf to root."""
    n = len(leaves)
    if index < 0 or index >= n:
        raise IndexError(f"leaf index {index} outside tree of size {n}")
    if n == 1:
        return []
    k = _split_point(n)
    if index < k:
        return inclusion_proof(leaves[:k], index) + [leaf_hashes_root(leaves[k:])]
    return inclusion_proof(leaves[k:], index - k) + [leaf_hashes_root(leaves[:k])]


def verify_inclusion_proof(
    leaf: bytes, index: int, tree_size: int, proof: list, root: bytes
) -> bool:
    """RFC 6962 section 2.1.1 verification, implemented as specified.

    Returns a bool rather than raising: a caller checking a proof is asking a
    question, and every failure mode here is "no", not "something went wrong".
    """
    if index < 0 or index >= tree_size:
        return False
    fn, sn = index, tree_size - 1
    computed = leaf
    for sibling in proof:
        if sn == 0:
            return False
        if (fn & 1) or fn == sn:
            computed = node_hash(sibling, computed)
            if not (fn & 1):
                while fn and not (fn & 1):
                    fn >>= 1
                    sn >>= 1
        else:
            computed = node_hash(computed, sibling)
        fn >>= 1
        sn >>= 1
    return sn == 0 and computed == root
