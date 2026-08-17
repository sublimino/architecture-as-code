"""An audit event is a side effect of the action the API itself performs.

Stated as an invariant, because it is the thing that was never written down and
so was violated in four different places at once:

    An audit event is a side effect of the action the API itself performs. It
    is never content the client supplies, never a record of an action performed
    elsewhere, and never written by a browser.

``test_audit_event_types.py`` checks that what we write is *permitted*.
``test_write_transactions.py`` checks that it is *atomic*. Neither asks whether
it is *true*, and a permitted, atomic lie is still a lie -- worse than a
missing row, because a missing row prompts the question and a fabricated one
answers it wrongly. That gap is what this file closes.

Four incidents, all live in the tree when this was written:

* ``POST /agents/{id}/stun`` took ``reason``, ``outcome``, ``namespace`` and
  ``agent_name`` from the request body. ``StunAgentRequest``'s own docstring
  said the quiet part out loud -- "the SuperCred proxy performs the cluster-side
  action and this endpoint records it". ``outcome`` is the sharp one: it
  defaults to the success value ``"stunned"`` while the handler's docstring
  concedes it "cannot tell you whether the cluster action succeeded". A client
  asserting the outcome of an action this process did not perform is not
  evidence, it is testimony recorded as evidence.

* ``agent_name`` in the same call was ``req.agent_name or row["name"]`` -- the
  client placed *ahead* of the server's own ``FOR UPDATE`` read. A caller could
  rename the subject of the record while the true name sat in a local variable
  one line above.

* ``onboarding.py`` recorded ``actor="onboarding-api"``, a module constant. The
  human who clicked the button was resolved, cached by FastAPI, in scope, and
  discarded. ``test_no_audit_call_site_hardcodes_its_actor`` exists to catch
  exactly this and did not, because it tested for ``ast.Constant`` at the call
  site and a module-level name is an ``ast.Name``. Moving one literal behind a
  constant defeated the guard. That test is strengthened alongside this file.

* ``demo_runner.py`` fell back to an in-memory dict when it had no pool, and
  the deployed pod has no database configured at all. Every phase-run audit
  went to RAM and died with the process, and every test passed because tests
  supply a pool.

WHAT THIS FILE CAN AND CANNOT DECIDE
------------------------------------
It is honest about its own reach, because the failure mode it is guarding
against is a check that reads as coverage while providing none.

*Decidable, and decided here:* whether a value that reaches an audit write can
be traced syntactically to a request body; whether the handler also persists
that same field; whether a mutating route reaches an audit writer at all;
whether the audit row is issued against the same connection as the change it
describes; whether a handler audits while performing no observable action;
whether an audit writer has a non-durable branch; whether the browser posts to
an audit-recording route.

THREE THINGS THIS FILE CANNOT SEE
---------------------------------
Meet them here rather than by finding a case that slips through. A green run
means these three were not checked, not that they are fine.

1. **Whether a recorded value is true.** A handler that launders a client value
   through a variable the server also writes passes
   ``test_no_client_supplied_field_reaches_an_audit_write``. No AST analysis
   fixes this -- it is a property of values, not a shape in the tree. The
   persistence rule narrows it to "a laundered value must at least have been
   written to a business table", which is a real constraint and not nothing,
   but it is not proof. Reviewers still have to read stun-shaped handlers, and
   that requirement does not go away because a suite is green.

2. **Anything written in Go.** ``d2-signalloom/apps/fleet-manager/main.go``
   registers five cluster-mutating routes -- ``/fleet/deploy``,
   ``/fleet/stun/``, ``/fleet/scan``, ``/fleet/recover``, ``/fleet/reset`` --
   and the string "audit" does not appear anywhere in that service.
   ``/fleet/stun/`` is the endpoint that actually performs the enforcement
   action that ``POST /agents/{id}/stun`` merely narrates, so the system audits
   the narration and not the act. A Python AST guard cannot see Go. Recorded so
   the omission is deliberate and findable rather than an oversight.

3. **A persisted-but-sensitive field, which is permitted here by design.** The
   rule is "client content may reach an audit row if the handler also persisted
   it", so copying a field the handler stored always passes -- including one
   that should not be on the audit timeline at all. ``body.message`` on a
   support request is the live example: it is persisted to
   ``support_requests``, so this file would allow it into ``detail``, and it
   may contain credentials pasted from a log or another customer's name.
   ``test_write_transactions.test_the_support_audit_row_does_not_copy_the_
   message_body`` is the complementary cover, asserting on the stored row that
   the body does not appear. The two rules are deliberately different in kind:
   this file asks where a value came from, that one asks whether a specific
   value belongs. Neither generalises into the other, and this one was not
   stretched into a PII check it could not honestly perform.
"""
from __future__ import annotations

import ast
import re
from functools import lru_cache
from pathlib import Path

from tests.test_audit_event_types import _called_name, _source_modules


@lru_cache(maxsize=None)
def _parsed(path: Path) -> ast.Module:
    """Parse once per module per session.

    Not premature. ``api_compat.py`` is ~154 KB and several helpers here call
    ``_writer_parameters()``, which walks every module; without this the suite
    re-parsed it hundreds of times and this file took 60 seconds on its own. A
    guard slow enough to be irritating is a guard somebody excludes from the
    default run, and an excluded guard is the same as no guard.
    """
    return ast.parse(path.read_text(encoding="utf-8"))


@lru_cache(maxsize=1)
def _modules() -> tuple[Path, ...]:
    return tuple(_source_modules())

SRC_DIR = Path(__file__).resolve().parent.parent
DASHBOARD_SRC = (
    SRC_DIR.parent.parent / "dashboard-signalloom" / "src"
)

AUDIT_WRITERS = ("_audit_log", "_record_memory_audit")

# Receivers whose results are the *server's own observation* of state, and whose
# arguments therefore do not contaminate what comes back. A row read with
# ``WHERE id = $1`` parameterised by a client-supplied id is still a row the
# database produced; treating it as client content would flag every handler in
# the file and the guard would be turned off within a week.
DB_METHODS = frozenset({"execute", "fetch", "fetchrow", "fetchval"})

_MUTATIONS = ("INSERT", "UPDATE", "DELETE")
_MUTATION_IN_CTE = re.compile(r"\b(INSERT|UPDATE|DELETE)\b", re.IGNORECASE)


def _sql_writes(sql: str) -> bool:
    """True if ``sql`` mutates, directly or from inside a CTE.

    Same shape as ``test_write_transactions._sql_writes`` and for the same
    reason: ``revoke_agent_credential`` hides its UPDATE inside
    ``WITH revoked AS (UPDATE ... RETURNING 1)``, and a prefix-only test reads
    that as a SELECT.
    """
    statement = sql.lstrip()
    if statement.upper().startswith(_MUTATIONS):
        return True
    if not statement.upper().startswith("WITH"):
        return False
    return _MUTATION_IN_CTE.search(statement) is not None


def _sql_literal(node: ast.expr | None) -> str | None:
    """The SQL text of a query argument, including f-strings.

    ``ast.Constant`` is not enough, and the gap is not theoretical.
    ``test_write_transactions._is_mutating_call`` requires a ``Constant`` and
    therefore cannot see ``onboarding.py:183``:

        await conn.fetchrow(
            f'''UPDATE tenant_onboarding
                   SET status = $2, {column} = $3
                 WHERE tenant_id = $1 AND status <> $2
             RETURNING *''', ...)

    That is an ``ast.JoinedStr``, so the only mutating statement in the module
    is invisible to the atomicity guard -- in the module whose own docstring
    records having *already* been missed once by that file, for a different
    reason (it read only ``api_compat.py``). Two independent blind spots, same
    module, same guard.

    The interpolated parts are dropped and the literal parts joined. The
    fragment that produces is not valid SQL, but the leading keyword survives,
    and the leading keyword is the whole question.
    """
    if isinstance(node, ast.Constant):
        return str(node.value)
    if isinstance(node, ast.JoinedStr):
        return "".join(
            part.value for part in node.values
            if isinstance(part, ast.Constant) and isinstance(part.value, str)
        )
    return None


# ---------------------------------------------------------------------------
# Writer signatures, derived rather than restated
# ---------------------------------------------------------------------------

@lru_cache(maxsize=1)
def _writer_parameters() -> dict[str, list[str]]:
    """Positional parameter names of each audit writer, read from its ``def``.

    Hardcoding these is a trap this guard fell into during development, and it
    failed silently rather than loudly. ``_audit_log`` takes ``executor`` first
    and ``_record_memory_audit`` does not, so the two signatures are offset by
    one. A single hardcoded table read every ``_record_memory_audit`` argument
    one position out: it reported the ``detail`` expression under the name
    ``actor`` and the ``agent_name`` expression under ``agent_id``. Every
    finding was wrong and every one looked plausible.

    So the table is derived from the source. If someone reorders or inserts a
    parameter, this follows; it cannot drift out of step with the code it reads.
    """
    parameters: dict[str, list[str]] = {}
    for path in _modules():
        tree = _parsed(path)
        for node in ast.walk(tree):
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            if node.name in AUDIT_WRITERS and node.name not in parameters:
                parameters[node.name] = [a.arg for a in node.args.args]
    return parameters


def _audit_calls() -> list[tuple[Path, ast.AST, ast.Call]]:
    out: list[tuple[Path, ast.AST, ast.Call]] = []
    for path in _modules():
        tree = _parsed(path)
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and _called_name(node) in AUDIT_WRITERS:
                out.append((path, tree, node))
    return out


def _argument_named(call: ast.Call, parameter: str, order: list[str]) -> ast.expr | None:
    """The expression bound to ``parameter``, keyword or positional."""
    for keyword in call.keywords:
        if keyword.arg == parameter:
            return keyword.value
    index = order.index(parameter)
    return call.args[index] if len(call.args) > index else None


def test_the_writer_signatures_are_the_ones_this_file_assumes() -> None:
    """Guards the guard against the offset bug described in ``_writer_parameters``.

    Asserted on the resolved names, not on a count: a signature that keeps its
    arity while renaming or reordering a parameter is exactly the change that
    would silently repoint every check in this file at the wrong expression.
    """
    parameters = _writer_parameters()
    assert parameters.get("_audit_log") == [
        "executor", "tenant_id", "event_type", "agent_id", "agent_name", "actor", "detail",
    ], f"_audit_log's signature moved: {parameters.get('_audit_log')}"
    assert parameters.get("_record_memory_audit") == [
        "tenant_id", "event_type", "agent_id", "agent_name", "actor", "detail",
    ], f"_record_memory_audit's signature moved: {parameters.get('_record_memory_audit')}"


# ---------------------------------------------------------------------------
# 1. No client-supplied field reaches an audit write
# ---------------------------------------------------------------------------

def _request_model_names(tree: ast.AST) -> set[str]:
    """Pydantic models defined in this module -- i.e. request/response bodies."""
    return {
        node.name
        for node in ast.walk(tree)
        if isinstance(node, ast.ClassDef)
        for base in node.bases
        if getattr(base, "id", getattr(base, "attr", None)) == "BaseModel"
    }


def _body_parameters(function: ast.FunctionDef | ast.AsyncFunctionDef, models: set[str]) -> set[str]:
    """Parameters of ``function`` annotated with a request model.

    Scoped to *body* models on purpose. Path and query parameters are client
    input too, but they are addressing rather than content: ``agent_id`` in the
    URL names the row the handler then reads under ``WHERE id = $1 AND
    tenant_id = $2``, so what lands in the audit row is a value the server
    validated. Free text in a POST body is validated by nobody. Widening this
    to every ``str`` parameter would flag every handler and the guard would be
    switched off; saying so here is better than a silent narrowing.
    """
    found = set()
    for argument in [*function.args.args, *function.args.kwonlyargs]:
        if argument.annotation is None:
            continue
        annotated = {
            n.id for n in ast.walk(argument.annotation) if isinstance(n, ast.Name)
        }
        if annotated & models:
            found.add(argument.arg)
    return found


def _client_fields(expression: ast.expr, roots: set[str]) -> set[str]:
    """Field names read off a request body inside ``expression``.

    ``req.reason`` yields ``{"reason"}``. Tracked per *field* rather than per
    variable because the two questions this file asks -- "did the client supply
    it" and "did the handler also persist it" -- have different answers for
    different fields of the same body. ``patch_tenant_frameworks`` records
    ``body.selected_frameworks``, which it just wrote to ``tenant_settings``:
    that is the server recording its own write, and legitimate. A per-variable
    check cannot tell that apart from ``body.reason``, which is written nowhere.
    """
    fields = set()
    for node in ast.walk(expression):
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
            if node.value.id in roots:
                fields.add(node.attr)
    return fields


def _is_observation(expression: ast.expr) -> bool:
    """True if ``expression`` is a database read -- the taint barrier."""
    inner = expression.value if isinstance(expression, ast.Await) else expression
    return (
        isinstance(inner, ast.Call)
        and isinstance(inner.func, ast.Attribute)
        and inner.func.attr in DB_METHODS
    )


def _reaching_fields(
    function: ast.FunctionDef | ast.AsyncFunctionDef, roots: set[str],
) -> tuple[set[str], dict[str, set[str]]]:
    """``(roots, name -> request-body fields that can flow into it)``.

    Three propagation rules beyond plain assignment, all three needed by real
    code in this tree:

    * **Aliases of the body itself.** ``stun_agent`` opens with
      ``req = body or StunAgentRequest()`` and never touches ``body`` again.
      Tracking only *field access* on the declared parameter therefore found
      nothing in the one handler this whole file was written about: the
      analysis reported it clean and
      ``test_the_taint_analysis_still_sees_the_handlers_it_was_written_against``
      caught it. An assignment that mentions a root as a bare name makes its
      target a root too.

      That vacuity guard earning its keep on the first run is the argument for
      writing it. Every other assertion here would have been green.

    * **Closures.** ``stun_agent`` then builds its payload in a nested
      ``_detail()`` that closes over ``req``, ``reason`` and ``outcome`` and
      takes none of them as arguments. A caller-argument-only analysis sees
      ``_detail(from_state, registry_match=...)``, finds nothing
      client-supplied, and reports the handler clean a second way.

    * **Database reads are a barrier.** ``row = await conn.fetchrow(sql,
      agent_uuid, tenant_id)`` does not make ``row`` client content. Without
      this, every handler that reads a row by a client-supplied id is a
      violation, the test is noise, and it gets muted.
    """
    roots = set(roots)
    reaching: dict[str, set[str]] = {}

    def fields_of(expression: ast.expr) -> set[str]:
        if _is_observation(expression):
            return set()
        found = _client_fields(expression, roots)
        for node in ast.walk(expression):
            if isinstance(node, ast.Name) and node.id in reaching:
                found |= reaching[node.id]
        return found

    def aliases_a_root(expression: ast.expr) -> bool:
        """True if ``expression`` yields the body object itself, not a field of it.

        ``req = body or StunAgentRequest()`` aliases; ``reason = req.reason``
        reads a field. The distinction is whether the root name appears as the
        ``.value`` of an attribute access -- if it does, what flows out is the
        field, which the field tracking already handles.
        """
        if _is_observation(expression):
            return False
        read_from = {
            node.value.id
            for node in ast.walk(expression)
            if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name)
        }
        return any(
            isinstance(node, ast.Name) and node.id in roots and node.id not in read_from
            for node in ast.walk(expression)
        )

    # Iterate to a fixpoint: `detail = _detail(...)` can only be resolved after
    # `_detail` itself has been marked, and `_detail` only after `req`. Four
    # passes is well past saturation for anything in this tree; the loop is
    # bounded so a pathological module cannot hang the suite.
    for _ in range(4):
        for node in ast.walk(function):
            if isinstance(node, ast.Assign):
                if aliases_a_root(node.value):
                    for target in node.targets:
                        for name in ast.walk(target):
                            if isinstance(name, ast.Name):
                                roots.add(name.id)
                found = fields_of(node.value)
                if not found:
                    continue
                for target in node.targets:
                    for name in ast.walk(target):
                        if isinstance(name, ast.Name):
                            reaching.setdefault(name.id, set()).update(found)
            elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node is not function:
                # A nested function that reads a body field or a tainted local
                # returns tainted values.
                found = _client_fields(node, roots)
                for inner in ast.walk(node):
                    if isinstance(inner, ast.Name) and inner.id in reaching:
                        found |= reaching[inner.id]
                if found:
                    reaching.setdefault(node.name, set()).update(found)
    return roots, reaching


def _persisted_fields(
    function: ast.FunctionDef | ast.AsyncFunctionDef,
    roots: set[str],
    reaching: dict[str, set[str]],
) -> set[str]:
    """Request-body fields this handler writes to a business table.

    This is the line between the two cases the invariant distinguishes. A
    handler that records ``body.selected_frameworks`` after writing it to
    ``tenant_settings`` is recording *what it did*. A handler that records
    ``req.reason`` -- stored nowhere, checked by nobody, describing an action
    performed by a different process -- is recording *what it was told*.
    """
    persisted: set[str] = set()
    for node in ast.walk(function):
        if not isinstance(node, ast.Call):
            continue
        if not (isinstance(node.func, ast.Attribute) and node.func.attr in DB_METHODS):
            continue
        sql = _sql_literal(node.args[0]) if node.args else None
        if sql is None or not _sql_writes(sql):
            continue
        for parameter in [*node.args[1:], *(k.value for k in node.keywords)]:
            persisted |= _client_fields(parameter, roots)
            for name in ast.walk(parameter):
                if isinstance(name, ast.Name) and name.id in reaching:
                    persisted |= reaching[name.id]
    return persisted


# Fields the client supplies that reach an audit write and are stored nowhere
# else.
#
# EMPTY IS THE GOAL. Every entry is a defect with a note attached, not an
# exemption, and the note has to say who is removing it. The list is keyed on
# (module, handler, audit argument, field) rather than on the handler, so
# *widening* a known violation still fails -- a fifth client-supplied field on
# stun is a new defect even though stun is already listed.
#
# ``test_the_accepted_list_has_no_stale_entries`` makes the list self-cleaning:
# when a fix lands, its entry here goes red and has to be deleted. An exemption
# cannot outlive the defect it was written for.
ACCEPTED_CLIENT_SUPPLIED_FIELDS: dict[tuple[str, str, str, str], str] = {
    # ---- POST /agents/{id}/stun -- REMOVED 2026-08-14, defect fixed ---------
    #
    # Four entries lived here: detail.outcome, detail.reason, detail.namespace
    # and agent_name. They are gone because the handler stopped being a place
    # the browser told what to write down and started performing the cluster
    # action itself, so every field now has a server-side source -- identity
    # from the token, target from the path, prior state from its own FOR UPDATE
    # read, outcome and namespace from the proxy's own response.
    #
    # `StunAgentRequest` was deleted outright rather than trimmed. A body that
    # exists only to be ignored is an invitation to start honouring it again.
    #
    # This block is left as a comment rather than deleted silently because the
    # test that emptied it is the point: `test_the_accepted_list_has_no_stale_entries`
    # named all four the moment the fix landed and refused to pass until they
    # were removed. An exemption cannot outlive its defect.
    #
    # ---- POST /api/audit/privileged-invocations ----------------------------
    ("api_compat.py", "record_privileged_invocation", "event_type", "kind"): (
        "ACCEPTED, and the one entry in this dict that is a design rather than "
        "a defect awaiting a fix. `kind` selects between 'demo.phase_run' and "
        "'demo.reset_requested' -- a two-valued closed set, validated by the "
        "request model, not free text the caller composes.\n\n"
        "It is client-supplied because it has to be: the runner is the only "
        "process that knows which privileged control it is about to invoke, "
        "and it cannot be absorbed into this API because that pod exists to "
        "carry kubectl and the repo scripts, which this one does not. The "
        "honest handling is not to pretend the value was observed here -- the "
        "row carries `reported_by: supercred-demo-runner` and `observed: "
        "False` alongside it, so the provenance travels with the claim.\n\n"
        "Note what is NOT taken from the wire: actor and tenant come from the "
        "forwarded token, and `preempts_active_run` is derived from `kind` "
        "here rather than accepted from the body, because it is a property of "
        "the operation and not something a caller should be able to assert."
    ),
    # ---- POST /agents/{id}/transition --------------------------------------
    ("api_compat.py", "transition_agent", "detail", "reason"): (
        "Materially weaker than the stun case and listed separately so it is "
        "not fixed by reflex. This endpoint DOES perform the transition, so a "
        "caller-supplied justification is legitimate evidence of intent -- a "
        "human's stated reason for an action they really took. The defect is "
        "that it is stored unlabelled, indistinguishable from something the "
        "server established. The fix is a key name that says whose claim it "
        "is, not deletion of the field."
    ),
    # ---- POST /compliance/policy/scan --------------------------------------
    ("api_compat.py", "_db_policy_scan", "detail", "policyVersion"): (
        "Found by this guard rather than by review, and not otherwise on "
        "anyone's list. The scan audit records the policy version the CALLER "
        "named. Its sibling field `request.frameworks` is genuinely persisted "
        "by the same handler and so passes; policyVersion is stored nowhere. "
        "A compliance scan record that cites an unverified policy version is a "
        "regulatory artefact asserting something the system never checked."
    ),
}


@lru_cache(maxsize=1)
def _client_supplied_violations() -> list[tuple[tuple[str, str, str, str], str]]:
    """Every request-body field reaching an audit write without being persisted."""
    order = _writer_parameters()
    violations: list[tuple[tuple[str, str, str, str], str]] = []

    for path in _modules():
        tree = _parsed(path)
        models = _request_model_names(tree)
        if not models:
            continue
        for function in ast.walk(tree):
            if not isinstance(function, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            roots = _body_parameters(function, models)
            if not roots:
                continue
            calls = [
                node for node in ast.walk(function)
                if isinstance(node, ast.Call) and _called_name(node) in AUDIT_WRITERS
            ]
            if not calls:
                continue

            roots, reaching = _reaching_fields(function, roots)
            persisted = _persisted_fields(function, roots, reaching)

            for call in calls:
                writer = _called_name(call)
                for parameter in ("event_type", "agent_id", "agent_name", "actor", "detail"):
                    expression = _argument_named(call, parameter, order[writer])
                    if expression is None:
                        continue
                    supplied = _client_fields(expression, roots)
                    for name in ast.walk(expression):
                        if isinstance(name, ast.Name) and name.id in reaching:
                            supplied |= reaching[name.id]
                    for field in sorted(supplied - persisted):
                        key = (path.name, function.name, parameter, field)
                        violations.append((key, f"{path.name}:{call.lineno}"))
    return violations


# A synthetic handler carrying every propagation shape the analysis has to
# follow. Pinned here rather than asserted against live code on purpose.
#
# The first version of this vacuity guard asserted "stun_agent still resolves
# client-supplied fields". It caught a real bug during development -- and then
# the reintroduction harness showed it going RED when stun was *fixed*, because
# a fixed handler correctly resolves nothing. A guard that fails when the defect
# is repaired teaches everyone to delete it, and it would have been deleted
# along with the two rules underneath it.
#
# So the capability is tested against a fixture that cannot be fixed, and the
# live tree is only checked for non-vacuity.
_TAINT_FIXTURE = '''
from pydantic import BaseModel

class Thing(BaseModel):
    narrative: str | None = None
    stored: str | None = None

async def handler(body: Thing | None = None):
    req = body or Thing()                       # 1. alias of the body itself
    narrative = req.narrative or "default"      # 2. field read through the alias
    row = await conn.fetchrow("SELECT 1", req.stored)   # 3. observation barrier
    def _payload():                             # 4. closure over a tainted local
        return {"note": narrative, "seen": row}
    detail = _payload()
    await conn.execute("UPDATE t SET v = $1", req.stored)
    await _audit_log(conn, "t", "e", None, None, principal.actor, detail)
'''


def test_the_taint_analysis_follows_every_shape_it_has_to() -> None:
    """Guards the guard, against a fixture rather than against live code.

    Each assertion below names the production pattern it stands in for. All
    four were needed to see ``stun_agent`` at all, and the alias rule was
    missing on the first run -- the analysis reported the single most important
    handler in the file completely clean.
    """
    order = _writer_parameters()
    assert set(order) == set(AUDIT_WRITERS), f"audit writers not found: {sorted(order)}"

    tree = ast.parse(_TAINT_FIXTURE)
    models = _request_model_names(tree)
    assert models == {"Thing"}, f"request-model detection broke: {models}"

    function = next(
        n for n in ast.walk(tree)
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name == "handler"
    )
    roots = _body_parameters(function, models)
    assert roots == {"body"}, f"body-parameter detection broke: {roots}"

    roots, reaching = _reaching_fields(function, roots)

    assert "req" in roots, (
        "alias rule broken: `req = body or Thing()` no longer makes req a root. "
        "This is the rule stun_agent needs -- it aliases the body on its first "
        "line and never mentions the parameter again, so without this the "
        "handler resolves nothing and reads as clean."
    )
    assert reaching.get("narrative") == {"narrative"}, (
        f"field read through an alias broken: {reaching.get('narrative')}"
    )
    assert "row" not in reaching, (
        "observation barrier broken: a row read with a client-supplied "
        "parameter is being treated as client content. Without this every "
        "handler that reads by id is a violation, the test becomes noise, and "
        "it gets muted."
    )
    assert reaching.get("detail") == {"narrative"}, (
        f"closure rule broken: {reaching.get('detail')}. stun_agent builds its "
        "payload in a nested _detail() that closes over req and takes none of "
        "it as arguments; without this the call site reads as clean."
    )

    persisted = _persisted_fields(function, roots, reaching)
    assert persisted == {"stored"}, (
        f"persistence detection broke: {persisted}. This is the line between "
        "'the server recorded what it wrote' and 'the client dictated the "
        "evidence'; if it returns everything the guard permits everything."
    )


def test_the_analysis_is_not_vacuous_against_the_real_tree() -> None:
    """The fixture above can pass while the walk over real modules finds nothing.

    Deliberately weak -- it asserts only that *some* handler still resolves,
    not which. Naming a handler here is what made the previous version fail on
    a fix.
    """
    resolving: set[str] = set()
    for path in _modules():
        tree = _parsed(path)
        models = _request_model_names(tree)
        for function in ast.walk(tree):
            if not isinstance(function, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            roots = _body_parameters(function, models)
            if not roots:
                continue
            _, reaching = _reaching_fields(function, roots)
            if reaching:
                resolving.add(function.name)

    assert len(resolving) >= 5, (
        f"only {len(resolving)} handler(s) resolve any request-body flow "
        f"({sorted(resolving)}) -- module discovery or model detection has "
        "broken and the client-supplied check below is running on almost nothing"
    )


def test_no_client_supplied_field_reaches_an_audit_write() -> None:
    """The invariant, stated as an assertion.

    An audit row may record a value the client supplied only when the handler
    also *persisted* that value -- in which case the row is describing the
    write the handler performed. A field that appears in the audit trail and
    nowhere else is the client dictating the evidence.
    """
    violations = _client_supplied_violations()
    unexplained = [
        f"{where} {key[1]}(): audit argument {key[2]!r} carries client-supplied "
        f"{key[0].removesuffix('.py')}.{key[1]}.{key[3]!r}"
        for key, where in violations
        if key not in ACCEPTED_CLIENT_SUPPLIED_FIELDS
    ]
    assert not unexplained, (
        f"{len(unexplained)} audit write(s) carry content the client supplied "
        f"and the server never stored:\n  " + "\n  ".join(sorted(unexplained)) + "\n\n"
        "An audit event is a side effect of the action this API performed. "
        "Record what the server observed or wrote. If the value genuinely "
        "cannot come from anywhere else, persist it to a business table so the "
        "audit row is describing a write, or add it to "
        "ACCEPTED_CLIENT_SUPPLIED_FIELDS with the reason it is not a "
        "fabrication."
    )


def test_the_accepted_list_has_no_stale_entries() -> None:
    """An exemption for a call site that no longer exists hides the next one."""
    live = {key for key, _ in _client_supplied_violations()}
    stale = sorted(str(key) for key in ACCEPTED_CLIENT_SUPPLIED_FIELDS if key not in live)
    assert not stale, (
        f"ACCEPTED_CLIENT_SUPPLIED_FIELDS names {len(stale)} call site(s) that no "
        f"longer violate: {stale}. Remove them -- a stale exemption silently "
        "covers whatever moves into its place."
    )


# ---------------------------------------------------------------------------
# 2. Every mutating route makes an audit decision
# ---------------------------------------------------------------------------

MUTATING_METHODS = frozenset({"post", "put", "patch", "delete"})

# Mutating routes that deliberately write no audit event, each with the reason.
# Silence is the thing being prevented: an unaudited route should be a decision
# somebody made and signed, not a gap nobody noticed.
NOT_AUDIT_WORTHY: dict[tuple[str, str], str] = {
    ("onboarding.py", "onboarding_put_state"): (
        "Wizard scratch state -- which step the user is on, what they have typed "
        "so far. It is overwritten on every keystroke-ish save and holds no "
        "claim anybody would later need to evidence. The terminal transitions "
        "that do matter (skip, complete) are audited by _terminal_transition."
    ),
    ("signal_fusion.py", "run_correlation"): (
        "Correlation is a read-only computation over existing observations. "
        "It creates provisional actors but does not mutate user-visible state. "
        "The audit-worthy event is actor promotion, not the correlation run."
    ),
    ("signal_fusion.py", "seed_collectors"): (
        "Seeds fixture observations for the demo estate. Demo-only endpoint "
        "that writes synthetic data; the observations themselves are the record."
    ),
}

# Routes where the audit decision is genuinely open. Deliberately a separate
# dict from NOT_AUDIT_WORTHY: filing an unresolved question under "not audit
# worthy" would be recording a decision nobody made, which is the same species
# of error this file exists to prevent. An entry here is a debt with a name on
# it, and it reads as one.
AUDIT_DECISION_OWED: dict[tuple[str, str], str] = {
    ("signal_fusion.py", "promote_actor"): (
        "RULED AUDIT-WORTHY; the event is not written yet. "
        "POST /actors/{actor_id}/promote transitions a provisional actor to "
        "an issued identity in the agent_registry. That is the highest-stakes "
        "state change in Signal Fusion — the closing beat of the three-act demo "
        "and the action a regulator would want evidence of. The Go service owns "
        "the signal_audit_trail table and will write the event; the Python proxy "
        "should verify it landed. Delete this entry when the audit write is "
        "confirmed end-to-end."
    ),
    ("api_compat.py", "network_tests_scan"): (
        "RULED AUDIT-WORTHY; the event is not written yet. "
        "POST /network-tests/scan fires an active network reachability probe "
        "at the cluster through the integration proxy and records nothing. An "
        "operator-initiated active scan is exactly the class of action a "
        "regulated customer expects a record of, and the handler can reach the "
        "Principal already -- it currently takes authenticated_tenant, which is "
        "authenticated_principal's own wrapper. Owned by the endpoints agent. "
        "Delete this entry when the event lands; do NOT move it to "
        "NOT_AUDIT_WORTHY, that question has been answered."
    ),
}


def _route_decorators(
    function: ast.FunctionDef | ast.AsyncFunctionDef,
) -> list[tuple[str, str]]:
    """``(VERB, path)`` for each mutating route decorator on ``function``."""
    routes = []
    for decorator in function.decorator_list:
        if not isinstance(decorator, ast.Call):
            continue
        func = decorator.func
        if isinstance(func, ast.Attribute) and func.attr in MUTATING_METHODS:
            path = (
                decorator.args[0].value
                if decorator.args and isinstance(decorator.args[0], ast.Constant)
                else "?"
            )
            routes.append((func.attr.upper(), str(path)))
    return routes


def _reaches_an_audit_writer(name: str, table: dict[str, ast.AST], depth: int = 0) -> bool:
    """Whether ``name`` can reach an audit writer within four call hops.

    One hop is not enough and this is not hypothetical. ``demo_runner``'s
    routes audit through ``_record_run_audit``; ``onboarding``'s audit through
    ``_terminal_transition``. A direct-call check reports seven mutating routes
    as unaudited when two are genuinely unaudited -- five false alarms, which is
    how a guard gets muted.
    """
    if depth > 4 or name in AUDIT_WRITERS:
        return name in AUDIT_WRITERS
    node = table.get(name)
    if node is None:
        return False
    for child in ast.walk(node):
        if not isinstance(child, ast.Call):
            continue
        called = _called_name(child)
        if called and called != name and _reaches_an_audit_writer(called, table, depth + 1):
            return True
    return False


@lru_cache(maxsize=1)
def _function_table() -> dict[str, ast.AST]:
    table: dict[str, ast.AST] = {}
    for path in _modules():
        tree = _parsed(path)
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                table.setdefault(node.name, node)
    return table


@lru_cache(maxsize=1)
def _mutating_routes() -> list[tuple[str, str, str, str, bool]]:
    """``(module, handler, verb, path, audited)`` for every mutating route."""
    table = _function_table()
    routes = []
    for path in _modules():
        tree = _parsed(path)
        for node in ast.walk(tree):
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            for verb, route in _route_decorators(node):
                routes.append(
                    (path.name, node.name, verb, route, _reaches_an_audit_writer(node.name, table)),
                )
    return routes


def test_the_route_enumeration_is_not_empty() -> None:
    """Guards the guard: no routes found means the test below asserts nothing."""
    routes = _mutating_routes()
    assert len(routes) >= 20, f"only found {len(routes)} mutating routes -- discovery is broken"
    assert any(r[1] == "stun_agent" for r in routes), "stun_agent is not being discovered"


def test_every_mutating_route_makes_an_audit_decision() -> None:
    """Either it audits, or it says in NOT_AUDIT_WORTHY why it does not."""
    declared = {**NOT_AUDIT_WORTHY, **AUDIT_DECISION_OWED}
    silent = [
        f"{module}:{handler} ({verb} {route})"
        for module, handler, verb, route, audited in _mutating_routes()
        if not audited and (module, handler) not in declared
    ]
    assert not silent, (
        f"{len(silent)} mutating route(s) neither write an audit event nor "
        f"declare why they should not:\n  " + "\n  ".join(sorted(silent)) + "\n\n"
        "Add the audit write, or add an entry to NOT_AUDIT_WORTHY stating the "
        "reason. An unaudited mutation should be a decision on the record, not "
        "a gap."
    )


def test_the_not_audit_worthy_list_has_no_stale_entries() -> None:
    """A route that starts auditing must leave this list, or it reads as unaudited."""
    routes = {(module, handler) for module, handler, _, _, _ in _mutating_routes()}
    audited = {
        (module, handler)
        for module, handler, _, _, is_audited in _mutating_routes()
        if is_audited
    }
    stale = sorted(
        f"{module}:{handler}"
        for module, handler in {**NOT_AUDIT_WORTHY, **AUDIT_DECISION_OWED}
        if (module, handler) not in routes or (module, handler) in audited
    )
    assert not stale, (
        f"NOT_AUDIT_WORTHY / AUDIT_DECISION_OWED name {len(stale)} route(s) that "
        f"no longer need it (gone, or now audited): {stale}. Remove them -- a "
        "stale entry silently covers whatever moves into its place."
    )


# ---------------------------------------------------------------------------
# 3. No new non-durable audit path
# ---------------------------------------------------------------------------

# Call sites of the in-memory audit writer, by (module, enclosing function).
#
# WHY THIS IS AN INVENTORY AND NOT A BAN
# --------------------------------------
# The fixture path exists so the product demos with no database, and deleting
# it is a product decision rather than a test's. What must not happen is a
# *new* one appearing unnoticed, which is exactly how demo_runner's arrived:
# the deployed runner pod has no database configuration at all, so every
# phase-run and reset audit went to a dict that dies with the pod, and every
# test passed because tests supply a pool.
#
# The reason the fallback is not merely weak but actively misleading:
# _record_memory_audit mints ids like "{tenant}:audit-mem-7" and GET /api/audit
# serves those rows in the same AuditListResponse, in the same shape, ahead of
# the durable ones. A consumer cannot tell a volatile row from a durable row
# without knowing that id convention. So the fallback does not just fail to
# persist evidence -- it manufactures evidence-shaped objects and hands them
# back through the evidence API. That is why adding one has to be deliberate.
KNOWN_VOLATILE_AUDIT_SITES: dict[tuple[str, str], str] = {
    ("api_compat.py", "stun_agent"): (
        "Fixture path for the no-database demo. Its sibling defect -- the "
        "fabricated active -> suspended transition -- was fixed in both paths "
        "at once precisely because this is the path the demo actually serves."
    ),
    ("api_compat.py", "patch_user_preferences"): (
        "Fixture path for per-user display currency with no database."
    ),
    ("demo_runner.py", "_record_privileged_invocation"): (
        "Fixture path only, and no longer the production path. The runner now "
        "forwards to POST /api/audit/privileged-invocations on fe-signalloom "
        "with the operator's own token, and demo_runner_main.py's /readyz "
        "refuses to report ready when neither a sink URL nor a local pool is "
        "configured -- so a deployed runner never joins its Service rather than "
        "accepting privileged calls and recording them nowhere. What remains "
        "here serves tests and the no-database demo."
    ),
    ("api_compat.py", "record_privileged_invocation"): (
        "The receiving half of the same path. No pool means fixture mode, in "
        "which every audit writer in this module is volatile; this one is not "
        "special. In a deployed fe-signalloom the pool exists, which is the "
        "case the runner's readiness probe is asserting on the other side."
    ),
    ("api_compat.py", "request_reassessment"): (
        "Fixture path for the no-database demo, same as its siblings. Its "
        "separate defect -- claiming a reassessment had been requested when "
        "nothing was queued -- was fixed by recording `dispatched: False` in "
        "both paths rather than by removing the row, because an operator "
        "pressing the control is itself worth a record even when the platform "
        "does nothing with it."
    ),
}


@lru_cache(maxsize=1)
def _volatile_audit_sites() -> dict[tuple[str, str], int]:
    sites: dict[tuple[str, str], int] = {}
    for path in _modules():
        tree = _parsed(path)
        for function in ast.walk(tree):
            if not isinstance(function, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            for node in ast.walk(function):
                if isinstance(node, ast.Call) and _called_name(node) == "_record_memory_audit":
                    sites.setdefault((path.name, function.name), node.lineno)
    return sites


def test_no_new_non_durable_audit_path_has_been_added() -> None:
    """A new in-memory audit writer must be argued for, not merely written.

    Asserted on the resolved set of call sites, not on a count: swapping one
    volatile writer for another keeps the count and changes the risk.
    """
    sites = _volatile_audit_sites()
    undeclared = sorted(
        f"{module}:{function} (line {line})"
        for (module, function), line in sites.items()
        if (module, function) not in KNOWN_VOLATILE_AUDIT_SITES
    )
    assert not undeclared, (
        f"{len(undeclared)} audit write(s) go to memory instead of the database "
        f"and are not declared:\n  " + "\n  ".join(undeclared) + "\n\n"
        "An in-memory audit row is served back through GET /api/audit in the "
        "same shape as a durable one, so it is not a degraded record -- it is a "
        "fabricated one with a short life. If this really is a fixture-only "
        "path, add it to KNOWN_VOLATILE_AUDIT_SITES with the reason."
    )


def test_the_volatile_site_inventory_has_no_stale_entries() -> None:
    sites = _volatile_audit_sites()
    stale = sorted(
        f"{module}:{function}"
        for module, function in KNOWN_VOLATILE_AUDIT_SITES
        if (module, function) not in sites
    )
    assert not stale, (
        f"KNOWN_VOLATILE_AUDIT_SITES names {len(stale)} site(s) that no longer "
        f"call _record_memory_audit: {stale}. Remove them."
    )


# ---------------------------------------------------------------------------
# 4. The audit write is coupled to the action it records
# ---------------------------------------------------------------------------
#
# WHAT THIS SECTION CAN AND CANNOT CHECK -- READ THIS BEFORE TRUSTING IT
# ---------------------------------------------------------------------
# The invariant has two halves and only one of them is decidable here.
#
#   Decidable: does the audit row commit with the state change (same
#   connection, same transaction), and does the handler perform any observable
#   action at all. Both are structural properties of the syntax.
#
#   NOT decidable: whether the row records what the server OBSERVED rather than
#   what it was TOLD. A handler that launders a client value through a variable
#   the server also writes satisfies every check in this file. There is no AST
#   analysis that fixes that -- it is a semantic property of the values, not a
#   shape in the tree.
#
# This is stated here rather than papered over because the alternative is worse
# than the gap. A check that reads as covering semantics it cannot cover is the
# same defect as a comment crediting a test with coverage it lacks, and this
# codebase has been bitten by that repeatedly -- test_audit_event_types.py read
# one module while claiming to read the source, then understood only literals
# while claiming to resolve call sites. Naming the boundary is worth more than
# extending the check until it looks complete.
#
# So: `test_no_client_supplied_field_reaches_an_audit_write` narrows the gap to
# "a laundered value must at least have been persisted", which is a real
# constraint and not nothing. It is not proof the row is true. Reviewers still
# have to read stun-shaped handlers, and that requirement does not go away
# because a suite is green.

# Audit writes whose action is real but is not a database write. Each entry
# must say what the action IS and what makes the record trustworthy without a
# transaction to bind to.
#
# The distinction this dict draws is the one the invariant turns on. "The
# handler performs no database write" has two completely different causes:
# the action happened somewhere this process can still vouch for (a subprocess
# it spawned), or the action did not happen at all and the row is a claim about
# elsewhere. Only the first is legitimate, and only a human can tell them apart,
# so each one is written down.
RECORDS_A_NON_DATABASE_ACTION: dict[tuple[str, str], str] = {
    ("demo_runner.py", "_record_privileged_invocation"): (
        "LEGITIMATE. The state change is a subprocess and a mutated cluster, "
        "not a row, so there is no transaction to bind to. Ordering is the "
        "guarantee instead: audit first, spawn second, so a spawn cannot occur "
        "without a record and a failed audit means no run. Note what it does "
        "NOT claim -- it records which step, which principal, when, and "
        "deliberately not an outcome, because the SuperCred proxy performs the "
        "cluster half and reports to nobody. (Its durability is a separate "
        "defect; see KNOWN_VOLATILE_AUDIT_SITES.)"
    ),
    ("api_compat.py", "request_reassessment"): (
        "LEGITIMATE now, and it was a defect when this entry was written. The "
        "handler still performs no INSERT, UPDATE, outbound call or subprocess "
        "-- but the row no longer claims one did. It records `dispatched: "
        "False`, so what it asserts is exactly what happened: an operator "
        "pressed a control and the platform queued nothing. That is worth a "
        "record. The original defect was not the absence of an action, it was "
        "a row and a response asserting `reassessment_requested` while nothing "
        "had been requested of anything."
    ),
    ("api_compat.py", "record_privileged_invocation"): (
        "LEGITIMATE. The receiving half of the runner's forward. The action is "
        "a subprocess spawn in another pod, so there is no row here to bind a "
        "transaction to -- the runner holds the ordering guarantee (audit "
        "first, spawn second, a failed forward means no run) and this endpoint "
        "holds the durability.\n\n"
        "What makes it trustworthy without a transaction is that it does not "
        "pretend to be a first-party observation. The row carries "
        "`reported_by: supercred-demo-runner` and `observed: False`, so a "
        "reader knows which grade of evidence they are holding without needing "
        "to know this endpoint exists. Everything else is re-derived here: the "
        "actor and tenant from the forwarded token, the event type from `kind` "
        "against a closed set, `preempts_active_run` from the operation rather "
        "than from the body.\n\n"
        "This is the deliberate asymmetry with the stun. The API absorbed the "
        "stun because it COULD -- the proxy call is one HTTP request on a path "
        "fe-signalloom already uses. It cannot absorb the runner: that pod "
        "exists precisely because it carries kubectl and the repo scripts, "
        "which the API pod does not. So the actor stays where it is and only "
        "the storage moves. Structural, not convenient."
    ),
}


def _mutating_receivers(function: ast.FunctionDef | ast.AsyncFunctionDef) -> set[str]:
    """Receiver names (``conn``, ``pool``) of every mutating statement."""
    receivers = set()
    for node in ast.walk(function):
        if not isinstance(node, ast.Call):
            continue
        if not (isinstance(node.func, ast.Attribute) and node.func.attr in DB_METHODS):
            continue
        sql = _sql_literal(node.args[0]) if node.args else None
        if sql is None or not _sql_writes(sql):
            continue
        receivers.add(
            node.func.value.id if isinstance(node.func.value, ast.Name) else "?"
        )
    return receivers


def _audit_executors(function: ast.FunctionDef | ast.AsyncFunctionDef) -> set[str]:
    """What each audit write in ``function`` is issued against."""
    order = _writer_parameters()
    executors = set()
    for node in ast.walk(function):
        if not (isinstance(node, ast.Call) and _called_name(node) in AUDIT_WRITERS):
            continue
        if _called_name(node) == "_record_memory_audit":
            executors.add("(memory)")
            continue
        expression = _argument_named(node, "executor", order["_audit_log"])
        executors.add(ast.unparse(expression) if expression is not None else "?")
    return executors


@lru_cache(maxsize=1)
def _auditing_functions() -> list[tuple[str, str, set[str], set[str]]]:
    """``(module, function, audit executors, mutating receivers)``."""
    out = []
    for path in _modules():
        tree = _parsed(path)
        for function in ast.walk(tree):
            if not isinstance(function, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            executors = _audit_executors(function)
            if executors:
                out.append(
                    (path.name, function.name, executors, _mutating_receivers(function)),
                )
    return out


def test_the_transaction_check_reads_every_module_and_every_sql_shape() -> None:
    """Guards the guard against the two blind spots it was written to close.

    ``test_write_transactions`` covers this property well for ``api_compat.py``
    and is not duplicated here. What it cannot see is asserted on directly:

    * it parses ``API_COMPAT`` only, so ``onboarding.py`` and
      ``demo_runner.py`` are outside it entirely, and
    * ``_is_mutating_call`` requires an ``ast.Constant``, so an f-string query
      is not a write as far as it is concerned.

    ``onboarding._terminal_transition`` is behind both at once. Asserted on the
    resolved receiver, so a regression in either shows up as a wrong value
    rather than an empty result.
    """
    found = {(module, name): receivers for module, name, _, receivers in _auditing_functions()}

    assert ("onboarding.py", "_terminal_transition") in found, (
        "onboarding._terminal_transition is not being discovered -- module "
        "discovery has regressed to a single file, which is the blind spot "
        "test_audit_event_types.py already had to fix once"
    )
    assert found[("onboarding.py", "_terminal_transition")] == {"conn"}, (
        f"onboarding._terminal_transition's UPDATE resolves to "
        f"{found[('onboarding.py', '_terminal_transition')]}, expected {{'conn'}}. "
        "Its query is an f-string; if this is empty, _sql_literal has stopped "
        "reading ast.JoinedStr and every f-string write in the tree is now "
        "invisible to this file."
    )


def test_an_audit_write_shares_the_connection_of_the_write_it_records() -> None:
    """One transaction, one connection -- across every module, not just one.

    A statement issued against the pool inside an open ``_write()`` block runs
    on a different connection and silently escapes the transaction, so the
    receiver is compared, not merely the presence of the helper.
    """
    split = []
    for module, name, executors, receivers in _auditing_functions():
        if not receivers:
            continue  # no state change here; the check below owns that case
        # (memory) is the fixture path and has no transaction by construction.
        durable = {e for e in executors if e != "(memory)"}
        if durable and durable != receivers:
            split.append(
                f"{module}:{name} audits against {sorted(durable)} but writes "
                f"through {sorted(receivers)}"
            )
    assert not split, (
        f"{len(split)} handler(s) write their audit row outside the transaction "
        f"that carries the change it describes:\n  " + "\n  ".join(sorted(split)) + "\n\n"
        "Every statement in the unit of work must use the connection yielded by "
        "_write(). A pool statement inside the block is a different connection "
        "and commits on its own, which is the failure migration 007 and _write "
        "exist to rule out: the business write lands, the audit row does not."
    )


def test_an_audit_write_with_no_action_behind_it_is_declared() -> None:
    """An audit row must describe something this process actually did.

    "The handler performs no database write" has two very different causes: the
    action was real but lives outside the database (a spawned subprocess), or
    there was no action and the row is a claim about somewhere else. The first
    is legitimate and the second is the violation this file is named for, and
    they are indistinguishable from the syntax -- so each one is written down.
    """
    undeclared = [
        f"{module}:{name}"
        for module, name, _, receivers in _auditing_functions()
        if not receivers and (module, name) not in RECORDS_A_NON_DATABASE_ACTION
    ]
    assert not undeclared, (
        f"{len(undeclared)} function(s) write an audit event without performing "
        f"any database write:\n  " + "\n  ".join(sorted(undeclared)) + "\n\n"
        "Either this records an action that really happened outside the "
        "database -- in which case add it to RECORDS_A_NON_DATABASE_ACTION "
        "saying what the action is and what makes the record trustworthy "
        "without a transaction -- or it is an endpoint whose only job is to "
        "record something that happened elsewhere, which is exactly what an "
        "audit event must never be."
    )


def test_the_non_database_action_declarations_are_all_still_needed() -> None:
    live = {(module, name) for module, name, _, r in _auditing_functions() if not r}
    stale = sorted(
        f"{module}:{name}"
        for module, name in RECORDS_A_NON_DATABASE_ACTION
        if (module, name) not in live
    )
    assert not stale, (
        f"RECORDS_A_NON_DATABASE_ACTION names {len(stale)} function(s) that now "
        f"perform a database write: {stale}. Remove them."
    )


# ---------------------------------------------------------------------------
# 5. The browser does not write the audit trail
# ---------------------------------------------------------------------------

# A mutating request from the dashboard whose path is an audit route. Written
# as a text scan rather than a TypeScript AST walk because the property is
# coarse -- does any browser module POST to /audit -- and a regex that is honest
# about being a regex beats a parser this repo would have to grow and trust.
_DASHBOARD_MUTATION = re.compile(
    r"""method:\s*['"](POST|PUT|PATCH|DELETE)['"]""", re.IGNORECASE,
)
_AUDIT_PATH = re.compile(r"""['"`][^'"`]*/audit[^'"`]*['"`]""")


def _dashboard_modules() -> list[Path]:
    """Non-test dashboard sources. Discovered, never listed."""
    if not DASHBOARD_SRC.is_dir():
        return []
    return sorted(
        p for p in DASHBOARD_SRC.rglob("*.ts*")
        if ".test." not in p.name and "__fixtures__" not in p.parts
    )


def test_the_dashboard_sources_are_actually_being_read() -> None:
    """Guards the guard: a wrong path makes the test below vacuous and green.

    DASHBOARD_SRC is a relative walk out of the Python package into a sibling
    app. A directory rename would leave the scan reading nothing at all, and an
    empty scan finds no violations -- the most comfortable possible failure.
    """
    modules = _dashboard_modules()
    assert len(modules) >= 50, (
        f"only found {len(modules)} dashboard modules under {DASHBOARD_SRC} -- "
        "the path is wrong and the browser-origin check below is vacuous"
    )
    assert any(p.name == "client.ts" for p in modules), "api/client.ts not found"


def test_the_browser_does_not_post_to_an_audit_route() -> None:
    """Audit rows are written by the API that performs the action, never by a tab.

    This replaced ``recordStunAudit()`` in SuperCredInstructorPanel.tsx, where
    the browser POSTed an audit event after a phase succeeded. Two things were
    wrong with it and only the first is obvious: the record was contingent on a
    tab staying open and a token staying valid, and its payload was a hardcoded
    string the client asserted rather than anything a server observed. A
    front-end that needs something audited calls the API that does the thing.
    """
    offenders = []
    for module in _dashboard_modules():
        source = module.read_text(encoding="utf-8")
        for line_number, line in enumerate(source.splitlines(), start=1):
            if _DASHBOARD_MUTATION.search(line) and _AUDIT_PATH.search(line):
                offenders.append(f"{module.name}:{line_number}: {line.strip()}")

    assert not offenders, (
        f"{len(offenders)} browser-side mutating request(s) to an audit route:\n  "
        + "\n  ".join(offenders) + "\n\n"
        "The browser must not write the audit trail. Call the API that performs "
        "the action; that API records it as a side effect of doing it."
    )
