"""``python -m audit_anchor`` -- checkpoint, verify, show.

    checkpoint   read the audit table up to a safe boundary, build the next
                 checkpoint in the chain, sign it, publish it
    verify       recompute every anchored window from the live table and
                 compare against the published anchors
    show         list the published anchors

Exit codes are the interface for CI:

    0   intact (or, for ``checkpoint``, published)
    2   DIVERGED -- the log does not match its anchors
    1   could not complete: unreachable database, missing key, bad artefact

2 is kept distinct from 1 deliberately. A verifier that exits non-zero for both
"tampering detected" and "I could not run" trains its operator to treat red as
noise, and the one time it matters they will treat it as noise too.
"""
import argparse
import asyncio
import json
import os
import sys

from audit_anchor.anchor import (
    AnchorError,
    IntegrityError,
    checkpoint_from_envelope,
    load_private_key,
    load_public_key,
    sign_envelope,
    store_from_env,
    build_statement,
    require_rekor_if_configured,
)
from audit_anchor.checkpoint import (
    GENESIS_DIGEST,
    PREDICATE_TYPE,
    Checkpoint,
    VerificationResult,
    build_checkpoint,
    verify_against_reader,
)
from audit_anchor.reader import (
    DEFAULT_SETTLE_LAG_SECONDS,
    AsyncpgAuditLogReader,
    choose_boundary,
    fetch_window_direct,
)
from audit_anchor.segments import (
    SEGMENT_SCOPE,
    JournalSegmentDigestReader,
    load_keyring,
)

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_DIVERGED = 2


def _source(value: str) -> str:
    """Expose ``both`` while retaining the uncommitted ``all`` spelling."""
    return "both" if value == "all" else value

# Checkpoint 0's window is open at the start. Printing a bare "None" at an
# operator reads like a bug in the tool at precisely the moment they are being
# asked to trust it.
BEGINNING_OF_LOG = "beginning of log"

DEFAULT_PRIVATE_KEY = ".keys/witness.pem"
DEFAULT_PUBLIC_KEY = ".keys/witness-pub.pem"


def _window(start, end) -> str:
    return f"({start or BEGINNING_OF_LOG} , {end}]"


def _load_chain(store, public_key, subject_prefix="signalloom-audit-checkpoint/"):
    """Fetch anchors, verify each signature, order them by index.

    Ordering by the signed index rather than by filename or by the order the
    store returned them: the store is not trusted to order anything, only to
    hold bytes.
    """
    checkpoints = [
        checkpoint_from_envelope(e, public_key)
        for e in store.fetch_all(subject_prefix)
    ]
    return sorted(checkpoints, key=lambda cp: cp.index)


def _load_segment_chain(store, keyring):
    chain = _load_trusted_chain(store, keyring, "signalloom-segment-checkpoint/")
    for checkpoint in chain:
        if checkpoint.tenant_scope != SEGMENT_SCOPE:
            raise IntegrityError(
                f"segment checkpoint {checkpoint.index} has unexpected tenant scope "
                f"{checkpoint.tenant_scope!r}"
            )
        if checkpoint.boundary_basis != "segment_sequence":
            raise IntegrityError(
                f"segment checkpoint {checkpoint.index} has unexpected boundary basis "
                f"{checkpoint.boundary_basis!r}"
            )
        boundaries = [checkpoint.window_end_inclusive]
        if checkpoint.window_start_exclusive is not None:
            boundaries.append(checkpoint.window_start_exclusive)
        if any(len(value) != 20 or not value.isdecimal() for value in boundaries):
            raise IntegrityError(
                f"segment checkpoint {checkpoint.index} boundary is not twenty-digit decimal"
            )
    return chain


def _load_trusted_chain(store, keyring, subject_prefix):
    checkpoints = []
    for envelope in store.fetch_all(subject_prefix):
        signatures = envelope.get("signatures", [])
        if not signatures:
            raise AnchorError("checkpoint has no signature")
        declared = signatures[0].get("keyid")
        statement = keyring.verify(envelope, declared)
        if statement.get("predicateType") != PREDICATE_TYPE:
            raise AnchorError("checkpoint has unexpected predicate type")
        checkpoint = Checkpoint.from_predicate(statement["predicate"])
        subject = statement.get("subject", [{}])[0]
        if subject.get("name") != checkpoint.subject_name():
            raise IntegrityError("checkpoint subject name disagrees with predicate")
        if subject.get("digest", {}).get("sha256") != checkpoint.digest():
            raise IntegrityError("checkpoint root/digest disagrees with signed subject")
        checkpoints.append(checkpoint)
    return sorted(checkpoints, key=lambda cp: cp.index)


def _combine_results(named_results):
    return VerificationResult(
        chain_issues=[issue for _, result in named_results for issue in result.chain_issues],
        divergences=[item for _, result in named_results for item in result.divergences],
        anchored_row_count=sum(result.anchored_row_count for _, result in named_results),
        unanchored_row_count=sum(result.unanchored_row_count for _, result in named_results),
        checkpoints_checked=sum(result.checkpoints_checked for _, result in named_results),
    )


def _sources_pass_gate(named_results) -> bool:
    """Require positive, complete evidence from each requested source."""
    return bool(named_results) and all(_passes_gate(result) for _, result in named_results)


def _sources_prove_anything(named_results) -> bool:
    return bool(named_results) and all(result.proves_anything for _, result in named_results)


def _passes_gate(result) -> bool:
    return (
        result.intact
        and result.proves_anything
        and result.checkpoints_checked > 0
        and result.unanchored_row_count == 0
    )


async def _connect(dsn):
    import asyncpg

    return await asyncpg.connect(dsn=dsn)


async def cmd_checkpoint(args) -> int:
    if args.source != "audit":
        raise AnchorError("segment checkpoint production is a Go flush-time responsibility")
    store, store_label = store_from_env(args.require_archivista)
    require_rekor_if_configured()
    private_key = load_private_key(args.private_key)
    public_key = load_public_key(args.public_key)

    chain = _load_chain(store, public_key)
    if chain:
        last = chain[-1]
        index, prev_digest = last.index + 1, last.digest()
        window_start, cumulative = last.window_end_inclusive, last.cumulative_row_count
        tenant_scope = last.tenant_scope
    else:
        index, prev_digest = 0, GENESIS_DIGEST
        window_start, cumulative = None, 0
        tenant_scope = args.tenant_scope

    conn = await _connect(args.dsn)
    try:
        boundary, basis = await choose_boundary(conn, args.settle_lag)
        if window_start is not None and boundary <= window_start:
            print(
                f"boundary {boundary} is not past the last checkpoint "
                f"({window_start}); nothing new can be safely anchored yet",
                file=sys.stderr,
            )
            return EXIT_ERROR
        rows = await fetch_window_direct(conn, tenant_scope, window_start, boundary)
    finally:
        await conn.close()

    checkpoint = build_checkpoint(
        rows,
        index=index,
        prev_checkpoint_digest=prev_digest,
        window_start_exclusive=window_start,
        window_end_inclusive=boundary,
        cumulative_row_count_before=cumulative,
        tenant_scope=tenant_scope,
        boundary_basis=basis,
    )
    envelope = sign_envelope(build_statement(checkpoint), private_key)
    reference = store.publish(checkpoint, envelope)

    print(f"checkpoint {checkpoint.index} published to {store_label}")
    print(
        "  window        "
        + _window(checkpoint.window_start_exclusive, checkpoint.window_end_inclusive)
    )
    print(f"  rows          {checkpoint.row_count} (cumulative {checkpoint.cumulative_row_count})")
    print(f"  merkle root   {checkpoint.merkle_root}")
    print(f"  digest        {checkpoint.digest()}")
    print(f"  prev          {checkpoint.prev_checkpoint_digest}")
    print(f"  boundary via  {checkpoint.boundary_basis}")
    print(f"  reference     {reference}")
    if checkpoint.boundary_basis == "settle_lag_only":
        print(
            "  NOTE: the transaction clamp was unavailable, so this boundary rests on a "
            f"{args.settle_lag}s settle lag rather than a proof that no writer can reach "
            "behind it.",
            file=sys.stderr,
        )
    return EXIT_OK


async def cmd_verify(args) -> int:
    store, store_label = store_from_env(args.require_archivista)
    require_rekor_if_configured()
    results = []
    if args.source in ("audit", "both"):
        if not args.expected_key_id:
            raise AnchorError(
                "audit verification requires at least one --expected-key-id; "
                "loading a public key does not establish its trusted identity"
            )
        expected = set(args.expected_key_id)
        audit_keyring = load_keyring(
            args.keyring or [args.public_key],
            revoked=args.revoked_key_id,
            expected=expected,
        )
        chain = _load_trusted_chain(
            store, audit_keyring, "signalloom-audit-checkpoint/"
        )
        conn = await _connect(args.dsn)
        try:
            scope = chain[0].tenant_scope if chain else args.tenant_scope
            reader = await AsyncpgAuditLogReader.load(conn, scope)
        finally:
            await conn.close()
        results.append(("audit", verify_against_reader(chain, reader)))
    if args.source in ("segments", "both"):
        key_paths = args.keyring or [args.public_key]
        if not args.expected_key_id:
            raise AnchorError(
                "segment verification requires at least one --expected-key-id; "
                "loading a public key does not establish its trusted identity"
            )
        expected = set(args.expected_key_id)
        if not args.protected_high_water:
            raise AnchorError(
                "segment verification requires --protected-high-water; signatures alone "
                "cannot detect checkpoint or journal rollback"
            )
        keyring = load_keyring(key_paths, revoked=args.revoked_key_id, expected=expected)
        segment_chain = _load_segment_chain(store, keyring)
        reader = JournalSegmentDigestReader(
            args.segment_journal,
            args.segment_root,
            keyring,
            high_water_path=args.protected_high_water,
            checkpoint_count=lambda: len(segment_chain),
        )
        results.append(("segments", verify_against_reader(segment_chain, reader)))

    result = _combine_results(results)
    passes_gate = _sources_pass_gate(results)

    if args.json:
        print(
            json.dumps(
                {
                    "status": "intact" if passes_gate else "diverged",
                    "anchor_store": store_label,
                    "checkpoints_checked": result.checkpoints_checked,
                    "anchored_row_count": result.anchored_row_count,
                    "unanchored_row_count": result.unanchored_row_count,
                    "proves_anything": _sources_prove_anything(results),
                    "chain_issues": [i.__dict__ for i in result.chain_issues],
                    "divergences": [d.__dict__ for d in result.divergences],
                },
                indent=2,
            )
        )
        return EXIT_OK if passes_gate else EXIT_DIVERGED

    print(f"anchor store        {store_label}")
    print(f"checkpoints checked {result.checkpoints_checked}")
    print(f"rows anchored       {result.anchored_row_count}")
    print(f"rows not yet anchored {result.unanchored_row_count}")

    if not result.proves_anything:
        print()
        print("NOTHING IS ANCHORED. This is not a clean bill of health -- no checkpoint")
        print("has been published, so no claim is being made about any row.")
        return EXIT_DIVERGED

    for issue in result.chain_issues:
        print(f"  CHAIN  [{issue.kind}] checkpoint {issue.checkpoint_index}: {issue.detail}")

    for divergence in result.divergences:
        print()
        print(f"  DIVERGED at checkpoint {divergence.checkpoint_index} [{divergence.kind}]")
        print(
            "    window     "
            + _window(divergence.window_start_exclusive, divergence.window_end_inclusive)
        )
        print(
            f"    rows       anchored {divergence.expected_row_count}, "
            f"found {divergence.observed_row_count}"
        )
        print(f"    root anchored  {divergence.expected_merkle_root}")
        print(f"    root observed  {divergence.observed_merkle_root}")

    print()
    if passes_gate:
        print("INTACT -- every anchored window still hashes to its published checkpoint.")
        return EXIT_OK

    first = result.first_divergence
    if first is not None:
        print(
            "DIVERGED -- the audit log no longer matches its anchors. The earliest "
            f"affected window is checkpoint {first.checkpoint_index}, covering "
            + _window(first.window_start_exclusive, first.window_end_inclusive)
            + "."
        )
    else:
        print("DIVERGED -- the checkpoint chain itself is malformed; see CHAIN above.")
    return EXIT_DIVERGED


async def cmd_show(args) -> int:
    store, store_label = store_from_env(args.require_archivista)
    prefixes = []
    if args.source in ("audit", "both"):
        prefixes.append("signalloom-audit-checkpoint/")
    if args.source in ("segments", "both"):
        prefixes.append("signalloom-segment-checkpoint/")
    if args.keyring:
        expected = set(args.expected_key_id) if args.expected_key_id else None
        keyring = load_keyring(args.keyring, revoked=args.revoked_key_id, expected=expected)
        chain = [cp for prefix in prefixes for cp in _load_trusted_chain(store, keyring, prefix)]
    else:
        public_key = load_public_key(args.public_key)
        chain = [cp for prefix in prefixes for cp in _load_chain(store, public_key, prefix)]
    print(f"anchor store {store_label}: {len(chain)} checkpoint(s)")
    for cp in chain:
        print(
            f"  {cp.index:>4}  rows {cp.row_count:>5} (cum {cp.cumulative_row_count:>6})  "
            f"root {cp.merkle_root[:16]}...  up to {cp.window_end_inclusive}  [{cp.boundary_basis}]"
        )
    return EXIT_OK


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="audit_anchor", description=__doc__)
    parser.add_argument(
        "--dsn",
        default=os.environ.get("DATABASE_URL"),
        help="Postgres DSN (default: $DATABASE_URL)",
    )
    parser.add_argument("--private-key", default=DEFAULT_PRIVATE_KEY)
    parser.add_argument("--public-key", default=DEFAULT_PUBLIC_KEY)
    parser.add_argument("--tenant-scope", default="*")
    parser.add_argument(
        "--source", type=_source, choices=("audit", "segments", "both"), default="audit"
    )
    parser.add_argument("--require-archivista", action="store_true")
    parser.add_argument("--segment-journal", default=os.environ.get("AUDIT_ANCHOR_SEGMENT_JOURNAL", "segments.jsonl"))
    parser.add_argument("--segment-root", default=os.environ.get("AUDIT_ANCHOR_SEGMENT_ROOT", "."))
    parser.add_argument("--protected-high-water", default=os.environ.get("AUDIT_ANCHOR_PROTECTED_HIGH_WATER"))
    parser.add_argument("--keyring", action="append", default=[])
    parser.add_argument("--expected-key-id", action="append", default=[])
    parser.add_argument("--revoked-key-id", action="append", default=[])
    sub = parser.add_subparsers(dest="command", required=True)

    checkpoint = sub.add_parser("checkpoint", help="build, sign and publish the next checkpoint")
    checkpoint.add_argument(
        "--source", type=_source, choices=("audit", "segments", "both"),
        default=argparse.SUPPRESS,
    )
    checkpoint.add_argument("--settle-lag", type=int, default=DEFAULT_SETTLE_LAG_SECONDS)
    checkpoint.set_defaults(func=cmd_checkpoint)

    verify = sub.add_parser("verify", help="recompute the live table against the anchors")
    verify.add_argument(
        "--source", type=_source, choices=("audit", "segments", "both"),
        default=argparse.SUPPRESS,
    )
    verify.add_argument("--json", action="store_true")
    verify.set_defaults(func=cmd_verify)

    show = sub.add_parser("show", help="list published anchors")
    show.add_argument(
        "--source", type=_source, choices=("audit", "segments", "both"),
        default=argparse.SUPPRESS,
    )
    show.set_defaults(func=cmd_show)

    args = parser.parse_args(argv)
    if args.command in ("checkpoint", "verify") and args.source in ("audit", "both") and not args.dsn:
        parser.error("--dsn or $DATABASE_URL is required")

    try:
        return asyncio.run(args.func(args))
    except IntegrityError as exc:
        if getattr(args, "json", False):
            print(json.dumps({
                "status": "diverged",
                "proves_anything": False,
                "checkpoints_checked": 0,
                "unanchored_row_count": None,
                "integrity_error": str(exc),
            }, indent=2))
        else:
            print(f"DIVERGED -- {exc}", file=sys.stderr)
        return EXIT_DIVERGED
    except (AnchorError, FileNotFoundError) as exc:
        if getattr(args, "json", False):
            print(json.dumps({"status": "error", "error": str(exc)}, indent=2))
        else:
            print(f"error: {exc}", file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
