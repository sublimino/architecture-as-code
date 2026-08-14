"""Checkpoints: scoped, chained commitments over windows of the audit log.

WHY A CHECKPOINT AND NOT ONE DIGEST OVER THE TABLE

A single digest recomputed over all of audit_events forever has two problems.
It is O(n) on every verification, which stops being free the moment the table is
interesting.  More importantly it cannot say WHEN something changed: it reports
one bit, and an auditor holding one red bit over four years of history has
learned almost nothing.

So each checkpoint commits to one window, (previous boundary, this boundary],
and carries the digest of the checkpoint before it.  The checkpoints chain even
though the rows do not yet.  Verification is per-window, divergence is reported
against the specific window it began in, and re-verifying only the recent past
is cheap enough to run continuously.

The cost, stated honestly: until the row-level chaining work lands, divergence
localises to a checkpoint window and no finer.  Checkpoint cadence is therefore
the resolution of the whole control.

THE BOUNDARY, AND ROWS ARRIVING DURING A CHECKPOINT

This is the part that is easy to get subtly wrong.

``audit_events.timestamp`` defaults to ``NOW()``, and in Postgres NOW() is
TRANSACTION START time, not statement time.  A transaction that began thirty
seconds ago and commits now writes a row stamped thirty seconds in the past.  So
"checkpoint everything up to now()" is wrong: rows can still appear behind the
boundary afterwards, and every one of them would report as a back-dated
insertion -- a false positive, which is the failure mode that gets a verifier
switched off.

``choose_boundary`` (in reader.py) resolves it structurally rather than by
hoping.  Any row an in-flight transaction can still write carries a timestamp of
at least that transaction's start time, so a boundary strictly below the oldest
in-flight transaction's start time cannot be reached by any writer that exists
yet.  Take that, and a settle-lag floor as a second line of defence, and
back-dating into an anchored window becomes impossible for an honest writer --
which is what licenses us to treat it as tampering when we see it.

Where the database role cannot see other sessions' transaction start times
(``pg_stat_activity.xact_start`` is masked without pg_read_all_stats), the
clamp is unavailable and only the settle lag applies.  That is weaker -- it is a
timeout assumption rather than a proof -- so the checkpoint records which basis
was used in ``boundary_basis``, inside the signed predicate.  An auditor can see
from the artefact alone whether a checkpoint rests on a proof or on an
assumption.
"""
from dataclasses import dataclass
from typing import Any, Protocol

from audit_anchor.canonical import encode_field, encode_row, leaf_hash, row_sort_key
from audit_anchor.merkle import leaf_hashes_root

CHECKPOINT_ENCODING_VERSION = "signalloom.audit.checkpoint/v1"

# The predicate type an in-toto Statement carries this under.
PREDICATE_TYPE = "https://controlplane.io/attestations/signalloom-audit-checkpoint/v1"

# Checkpoint 0 has no predecessor. An all-zero digest is a value no SHA256 will
# realistically produce, and it makes the genesis link explicit rather than
# encoding "no previous" as null -- which would have to be special-cased in the
# serialisation and is exactly where a length-extension-shaped bug lives.
GENESIS_DIGEST = "00" * 32

# Later than any timestamp the demo will hold, and comfortably inside the
# timestamptz range (which runs to year 294276). Used to sweep up rows past the
# last checkpoint.
FAR_FUTURE = "9999-12-31T23:59:59.999999Z"

VALID_BOUNDARY_BASES = ("xact_clamp", "settle_lag_only")


class ChainError(Exception):
    """A checkpoint was asked to commit to something it cannot honestly commit to."""


class AuditLogReader(Protocol):
    def fetch_window(
        self, tenant_scope: str, start_exclusive: str | None, end_inclusive: str
    ) -> list: ...


@dataclass(frozen=True)
class Checkpoint:
    tenant_scope: str
    index: int
    prev_checkpoint_digest: str
    window_start_exclusive: str | None
    window_end_inclusive: str
    row_count: int
    cumulative_row_count: int
    merkle_root: str
    boundary_basis: str

    def digest(self) -> str:
        """SHA256 over the same tag-and-length framing the rows use.

        One serialisation discipline for the whole subsystem rather than two.
        Every field is inside the digest: leave one out and an attacker can
        restate the checkpoint over a different window, or against a different
        tenant, and reuse the signature verbatim.
        """
        import hashlib

        parts = [
            encode_field(CHECKPOINT_ENCODING_VERSION),
            encode_field(self.tenant_scope),
            encode_field(str(self.index)),
            encode_field(self.prev_checkpoint_digest),
            encode_field(self.window_start_exclusive),
            encode_field(self.window_end_inclusive),
            encode_field(str(self.row_count)),
            encode_field(str(self.cumulative_row_count)),
            encode_field(self.merkle_root),
            encode_field(self.boundary_basis),
        ]
        return hashlib.sha256(b"".join(parts)).hexdigest()

    def subject_name(self) -> str:
        """Stable name for the in-toto subject, so anchors can be found again."""
        return f"signalloom-audit-checkpoint/{self.tenant_scope}/{self.index:08d}"

    def to_predicate(self) -> dict:
        return {
            "schema_version": CHECKPOINT_ENCODING_VERSION,
            "tenant_scope": self.tenant_scope,
            "index": self.index,
            "prev_checkpoint_digest": self.prev_checkpoint_digest,
            "window_start_exclusive": self.window_start_exclusive,
            "window_end_inclusive": self.window_end_inclusive,
            "row_count": self.row_count,
            "cumulative_row_count": self.cumulative_row_count,
            "merkle_root": self.merkle_root,
            "boundary_basis": self.boundary_basis,
        }

    @classmethod
    def from_predicate(cls, predicate: dict) -> "Checkpoint":
        version = predicate.get("schema_version")
        if version != CHECKPOINT_ENCODING_VERSION:
            raise ChainError(
                f"checkpoint schema {version!r} is not {CHECKPOINT_ENCODING_VERSION!r}; "
                "refusing to verify an artefact written by a different encoding"
            )
        return cls(
            tenant_scope=predicate["tenant_scope"],
            index=predicate["index"],
            prev_checkpoint_digest=predicate["prev_checkpoint_digest"],
            window_start_exclusive=predicate["window_start_exclusive"],
            window_end_inclusive=predicate["window_end_inclusive"],
            row_count=predicate["row_count"],
            cumulative_row_count=predicate["cumulative_row_count"],
            merkle_root=predicate["merkle_root"],
            boundary_basis=predicate["boundary_basis"],
        )


def merkle_root_over_rows(rows: list) -> str:
    """Sort canonically, encode, hash, build the tree. Returns hex."""
    ordered = sorted(rows, key=row_sort_key)
    leaves = [leaf_hash(encode_row(row)) for row in ordered]
    return leaf_hashes_root(leaves).hex()


def build_checkpoint(
    rows: list,
    *,
    index: int,
    prev_checkpoint_digest: str,
    window_start_exclusive: str | None,
    window_end_inclusive: str,
    cumulative_row_count_before: int,
    tenant_scope: str,
    boundary_basis: str,
) -> Checkpoint:
    if boundary_basis not in VALID_BOUNDARY_BASES:
        raise ChainError(f"boundary_basis {boundary_basis!r} not in {VALID_BOUNDARY_BASES}")
    if window_start_exclusive is not None and window_start_exclusive >= window_end_inclusive:
        raise ChainError(
            f"window ({window_start_exclusive}, {window_end_inclusive}] is empty or reversed"
        )

    # Refuse to commit to rows the declared window does not cover. A checkpoint
    # like that is unverifiable by construction: an honest verifier re-queries
    # the window, gets a different set, and reports tampering that never
    # happened.
    for row in rows:
        ts = row["ts"]
        if window_start_exclusive is not None and ts <= window_start_exclusive:
            raise ChainError(f"row {row['id']} at {ts} precedes the window start")
        if ts > window_end_inclusive:
            raise ChainError(f"row {row['id']} at {ts} is past the window end")
        if tenant_scope != "*" and row["tenant_id"] != tenant_scope:
            raise ChainError(f"row {row['id']} is outside tenant scope {tenant_scope}")

    return Checkpoint(
        tenant_scope=tenant_scope,
        index=index,
        prev_checkpoint_digest=prev_checkpoint_digest,
        window_start_exclusive=window_start_exclusive,
        window_end_inclusive=window_end_inclusive,
        row_count=len(rows),
        cumulative_row_count=cumulative_row_count_before + len(rows),
        merkle_root=merkle_root_over_rows(rows),
        boundary_basis=boundary_basis,
    )


# ══════════════════════════════════════════════════════════════════════════════
# Verification
# ══════════════════════════════════════════════════════════════════════════════


@dataclass(frozen=True)
class ChainIssue:
    kind: str
    checkpoint_index: int
    detail: str


@dataclass(frozen=True)
class Divergence:
    checkpoint_index: int
    kind: str
    window_start_exclusive: str | None
    window_end_inclusive: str
    expected_row_count: int
    observed_row_count: int
    expected_merkle_root: str
    observed_merkle_root: str


@dataclass(frozen=True)
class VerificationResult:
    chain_issues: list
    divergences: list
    anchored_row_count: int
    unanchored_row_count: int
    checkpoints_checked: int

    @property
    def intact(self) -> bool:
        return not self.chain_issues and not self.divergences

    @property
    def first_divergence(self):
        return self.divergences[0] if self.divergences else None

    @property
    def proves_anything(self) -> bool:
        """An empty chain is not evidence of anything.

        Reporting "intact" over zero anchored rows is the overclaim this whole
        component is supposed to avoid, so callers are made to ask separately.
        """
        return self.checkpoints_checked > 0


def verify_chain_structure(checkpoints: list) -> list:
    """Check the chain hangs together, before touching the database at all.

    These are the cheap checks and they catch the cheap attacks: deleting a
    checkpoint, re-pointing a back-link, moving a window boundary to open an
    unanchored gap where a deletion can hide.
    """
    issues = []
    for position, cp in enumerate(checkpoints):
        expected_index = checkpoints[0].index + position
        if cp.index != expected_index:
            issues.append(
                ChainIssue(
                    "index_gap",
                    cp.index,
                    f"expected checkpoint index {expected_index} at position {position}, "
                    f"found {cp.index} -- a checkpoint is missing or duplicated",
                )
            )
        if position == 0:
            if cp.index == 0 and cp.prev_checkpoint_digest != GENESIS_DIGEST:
                issues.append(
                    ChainIssue(
                        "broken_link",
                        cp.index,
                        "checkpoint 0 does not carry the genesis digest",
                    )
                )
            continue

        previous = checkpoints[position - 1]
        if cp.prev_checkpoint_digest != previous.digest():
            issues.append(
                ChainIssue(
                    "broken_link",
                    cp.index,
                    f"back-link {cp.prev_checkpoint_digest[:16]}... does not match "
                    f"checkpoint {previous.index} digest {previous.digest()[:16]}...",
                )
            )
        if cp.window_start_exclusive != previous.window_end_inclusive:
            issues.append(
                ChainIssue(
                    "window_gap",
                    cp.index,
                    f"window starts at {cp.window_start_exclusive} but the previous "
                    f"checkpoint ended at {previous.window_end_inclusive}; the interval "
                    "between them is anchored by nothing",
                )
            )
        if cp.cumulative_row_count != previous.cumulative_row_count + cp.row_count:
            issues.append(
                ChainIssue(
                    "cumulative_mismatch",
                    cp.index,
                    f"cumulative {cp.cumulative_row_count} != previous "
                    f"{previous.cumulative_row_count} + window {cp.row_count}",
                )
            )
        if cp.tenant_scope != previous.tenant_scope:
            issues.append(
                ChainIssue(
                    "tenant_scope_change",
                    cp.index,
                    f"scope changed from {previous.tenant_scope} to {cp.tenant_scope} "
                    "mid-chain; the two halves commit to different row sets",
                )
            )
    return issues


def verify_against_reader(checkpoints: list, reader: AuditLogReader) -> VerificationResult:
    """Recompute every anchored window from the live table and compare.

    Returns a result rather than raising, and reports EVERY diverged checkpoint
    rather than stopping at the first, because "when did this start and how far
    does it go" is the question an investigation actually asks.
    """
    issues = verify_chain_structure(checkpoints)
    divergences = []

    for cp in checkpoints:
        rows = reader.fetch_window(
            cp.tenant_scope, cp.window_start_exclusive, cp.window_end_inclusive
        )
        observed_root = merkle_root_over_rows(rows)
        if len(rows) != cp.row_count:
            kind = "row_count_mismatch"
        elif observed_root != cp.merkle_root:
            kind = "merkle_root_mismatch"
        else:
            continue
        divergences.append(
            Divergence(
                checkpoint_index=cp.index,
                kind=kind,
                window_start_exclusive=cp.window_start_exclusive,
                window_end_inclusive=cp.window_end_inclusive,
                expected_row_count=cp.row_count,
                observed_row_count=len(rows),
                expected_merkle_root=cp.merkle_root,
                observed_merkle_root=observed_root,
            )
        )

    if checkpoints:
        last = checkpoints[-1]
        unanchored = len(
            reader.fetch_window(last.tenant_scope, last.window_end_inclusive, FAR_FUTURE)
        )
        anchored = last.cumulative_row_count
    else:
        unanchored = len(reader.fetch_window("*", None, FAR_FUTURE))
        anchored = 0

    return VerificationResult(
        chain_issues=issues,
        divergences=divergences,
        anchored_row_count=anchored,
        unanchored_row_count=unanchored,
        checkpoints_checked=len(checkpoints),
    )
