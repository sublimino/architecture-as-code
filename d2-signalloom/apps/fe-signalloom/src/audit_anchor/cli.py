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
    checkpoint_from_envelope,
    load_private_key,
    load_public_key,
    sign_envelope,
    store_from_env,
    build_statement,
)
from audit_anchor.checkpoint import (
    GENESIS_DIGEST,
    build_checkpoint,
    verify_against_reader,
)
from audit_anchor.reader import (
    DEFAULT_SETTLE_LAG_SECONDS,
    AsyncpgAuditLogReader,
    choose_boundary,
    fetch_window_direct,
)

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_DIVERGED = 2

# Checkpoint 0's window is open at the start. Printing a bare "None" at an
# operator reads like a bug in the tool at precisely the moment they are being
# asked to trust it.
BEGINNING_OF_LOG = "beginning of log"

DEFAULT_PRIVATE_KEY = ".keys/witness.pem"
DEFAULT_PUBLIC_KEY = ".keys/witness-pub.pem"


def _window(start, end) -> str:
    return f"({start or BEGINNING_OF_LOG} , {end}]"


def _load_chain(store, public_key):
    """Fetch anchors, verify each signature, order them by index.

    Ordering by the signed index rather than by filename or by the order the
    store returned them: the store is not trusted to order anything, only to
    hold bytes.
    """
    checkpoints = [checkpoint_from_envelope(e, public_key) for e in store.fetch_all()]
    return sorted(checkpoints, key=lambda cp: cp.index)


async def _connect(dsn):
    import asyncpg

    return await asyncpg.connect(dsn=dsn)


async def cmd_checkpoint(args) -> int:
    store, store_label = store_from_env()
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
    store, store_label = store_from_env()
    public_key = load_public_key(args.public_key)
    chain = _load_chain(store, public_key)

    conn = await _connect(args.dsn)
    try:
        scope = chain[0].tenant_scope if chain else args.tenant_scope
        reader = await AsyncpgAuditLogReader.load(conn, scope)
    finally:
        await conn.close()

    result = verify_against_reader(chain, reader)

    if args.json:
        print(
            json.dumps(
                {
                    "status": "intact" if result.intact else "diverged",
                    "anchor_store": store_label,
                    "checkpoints_checked": result.checkpoints_checked,
                    "anchored_row_count": result.anchored_row_count,
                    "unanchored_row_count": result.unanchored_row_count,
                    "proves_anything": result.proves_anything,
                    "chain_issues": [i.__dict__ for i in result.chain_issues],
                    "divergences": [d.__dict__ for d in result.divergences],
                },
                indent=2,
            )
        )
        return EXIT_OK if result.intact else EXIT_DIVERGED

    print(f"anchor store        {store_label}")
    print(f"checkpoints checked {result.checkpoints_checked}")
    print(f"rows anchored       {result.anchored_row_count}")
    print(f"rows not yet anchored {result.unanchored_row_count}")

    if not result.proves_anything:
        print()
        print("NOTHING IS ANCHORED. This is not a clean bill of health -- no checkpoint")
        print("has been published, so no claim is being made about any row.")
        return EXIT_OK

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
    if result.intact:
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
    store, store_label = store_from_env()
    chain = _load_chain(store, load_public_key(args.public_key))
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
    sub = parser.add_subparsers(dest="command", required=True)

    checkpoint = sub.add_parser("checkpoint", help="build, sign and publish the next checkpoint")
    checkpoint.add_argument("--settle-lag", type=int, default=DEFAULT_SETTLE_LAG_SECONDS)
    checkpoint.set_defaults(func=cmd_checkpoint)

    verify = sub.add_parser("verify", help="recompute the live table against the anchors")
    verify.add_argument("--json", action="store_true")
    verify.set_defaults(func=cmd_verify)

    show = sub.add_parser("show", help="list published anchors")
    show.set_defaults(func=cmd_show)

    args = parser.parse_args(argv)
    if args.command in ("checkpoint", "verify") and not args.dsn:
        parser.error("--dsn or $DATABASE_URL is required")

    try:
        return asyncio.run(args.func(args))
    except (AnchorError, FileNotFoundError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
