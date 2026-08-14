"""Read-only extraction of audit rows, and the choice of checkpoint boundary.

Read-only is a hard property of this module, not a convention: there is no
INSERT, UPDATE or DELETE anywhere in it.  A component whose job is to attest to
a table's contents must not be able to change them, or the attestation is
attesting to its own output.
"""
from datetime import timedelta, timezone

from audit_anchor.checkpoint import FAR_FUTURE

# Every column projected to text, in SQL, so that no client driver sits inside
# the trust chain.  A Go verifier using pgx and a Python one using asyncpg must
# not have to agree about decoder behaviour -- only about this query.
#
# The timestamp rendering is the important one.  ``timestamptz::text`` follows
# the session's TimeZone and DateStyle, so two verifiers with different session
# settings read the same row and serialise different bytes.  ``to_char`` with an
# explicit ``AT TIME ZONE 'UTC'`` is independent of both, and ``US`` always emits
# six digits -- the full stored resolution, so nothing rounds away and there is
# no trailing-zero variant.
CANONICAL_TS_EXPR = (
    "to_char(timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')"
)

CANONICAL_ROW_SQL = f"""
    SELECT
        id::text        AS id,
        tenant_id       AS tenant_id,
        {CANONICAL_TS_EXPR} AS ts,
        event_type      AS event_type,
        agent_id::text  AS agent_id,
        agent_name      AS agent_name,
        actor           AS actor,
        detail::text    AS detail
      FROM public.audit_events
     WHERE ($1::text IS NULL OR timestamp > $1::text::timestamptz)
       AND timestamp <= $2::text::timestamptz
       AND ($3 = '*' OR tenant_id = $3)
"""

# The double cast is load-bearing. Written as ``$1::timestamptz``, asyncpg infers
# the parameter type as timestamptz and demands a datetime object; boundaries
# travel through this system as canonical ISO strings, and converting them back
# to datetimes at the edge would reintroduce exactly the client-side timezone
# handling that CANONICAL_TS_EXPR exists to keep out of the trust chain.

# Window bounds are compared as timestamptz rather than against the rendered
# text: it uses idx_audit_events_tenant_timestamp, and the comparison is exact
# because the canonical rendering is injective at microsecond resolution. The
# ISO 8601 form with a 'Z' offset parses identically under any DateStyle.

# How far behind the present a checkpoint boundary sits when the transaction
# clamp is unavailable. Five minutes is far longer than any request in this
# application, and it is only ever a fallback -- see choose_boundary.
DEFAULT_SETTLE_LAG_SECONDS = 300

_BOUNDARY_SQL = """
    SELECT
        now() AS now_ts,
        (SELECT min(xact_start)
           FROM pg_stat_activity
          WHERE datname = current_database()
            AND xact_start IS NOT NULL) AS oldest_xact,
        EXISTS (SELECT 1
                  FROM pg_stat_activity
                 WHERE backend_type = 'client backend'
                   AND pid <> pg_backend_pid()
                   AND state IS NULL) AS stats_masked
"""


def render_utc(dt) -> str:
    """Render a datetime exactly as CANONICAL_TS_EXPR renders a column.

    Used only for boundaries, which are computed from ``now()`` rather than read
    from a row. Row timestamps are never rendered here -- they come out of the
    database already in canonical form, which is the point.
    """
    dt = dt.astimezone(timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond:06d}Z"


async def choose_boundary(conn, settle_lag_seconds: int = DEFAULT_SETTLE_LAG_SECONDS):
    """Pick a boundary that no honest writer can still land behind.

    Returns ``(boundary_iso, basis)``.

    ``audit_events.timestamp`` defaults to ``NOW()``, and NOW() in Postgres is
    TRANSACTION START time, not statement time.  A transaction that began thirty
    seconds ago and commits now writes a row stamped thirty seconds ago.  So
    "anchor everything up to now()" is wrong: honest rows keep appearing behind
    the boundary afterwards, each one reported as a back-dated insertion.  False
    positives are how a verifier gets switched off.

    The fix is structural rather than hopeful.  Any row an in-flight transaction
    can still write carries a timestamp of at least that transaction's start
    time.  So a boundary strictly below the oldest in-flight transaction's start
    time is unreachable by every writer that currently exists, and a writer that
    does not exist yet will start later still.  Back-dating into an anchored
    window then requires a direct UPDATE or a forged timestamp -- which is
    precisely the tampering we want to report.

    Where the role cannot see other sessions' ``xact_start`` (masked without
    pg_read_all_stats), the clamp is unavailable and only the settle lag
    applies.  That is a timeout assumption, not a proof, so the basis travels
    inside the signed predicate and an auditor can tell the two apart from the
    artefact alone.
    """
    row = await conn.fetchrow(_BOUNDARY_SQL)
    now_ts, oldest_xact, stats_masked = row["now_ts"], row["oldest_xact"], row["stats_masked"]

    boundary = now_ts - timedelta(seconds=settle_lag_seconds)
    basis = "settle_lag_only"

    if not stats_masked:
        basis = "xact_clamp"
        if oldest_xact is not None:
            # Strictly below: a transaction stamped exactly at oldest_xact could
            # still write a row at that timestamp, and <= would admit it into an
            # already-anchored window.
            boundary = min(boundary, oldest_xact - timedelta(microseconds=1))

    return render_utc(boundary), basis


class AsyncpgAuditLogReader:
    """Reads windows of audit_events through an asyncpg connection.

    Synchronous ``fetch_window`` over an async driver is deliberate: the
    verification logic is a pure function of row sets, and threading async
    through it would buy nothing but colour.  Windows are pre-fetched by
    ``load``, which is possible precisely because the boundary makes every
    anchored window immutable -- there is nothing to stream.
    """

    def __init__(self, rows: list):
        self._rows = rows

    @classmethod
    async def load(cls, conn, tenant_scope: str = "*", up_to: str = FAR_FUTURE):
        records = await conn.fetch(CANONICAL_ROW_SQL, None, up_to, tenant_scope)
        return cls([dict(record) for record in records])

    def fetch_window(self, tenant_scope, start_exclusive, end_inclusive):
        return [
            row
            for row in self._rows
            if (start_exclusive is None or row["ts"] > start_exclusive)
            and row["ts"] <= end_inclusive
            and (tenant_scope == "*" or row["tenant_id"] == tenant_scope)
        ]

    def __len__(self):
        return len(self._rows)


async def fetch_window_direct(conn, tenant_scope, start_exclusive, end_inclusive):
    """One window, straight from the database. Used by the checkpoint builder."""
    records = await conn.fetch(
        CANONICAL_ROW_SQL, start_exclusive, end_inclusive, tenant_scope
    )
    return [dict(record) for record in records]
