"""The event types the code writes must be permitted by the CHECK constraint.

Every ``_audit_log()`` call site wrote a dotted event type while the constraint
allowed only an undotted vocabulary. The two sets were completely disjoint, so
every audit insert raised ``CheckViolationError`` — the business write had
already committed as a separate statement, so the endpoint persisted its change
and then returned 500. ``audit_events`` held zero rows on a cluster that had
been running for days.

Nothing caught it because the vocabulary lived in two places: string literals in
``api_compat.py`` and a hand-maintained list in SQL. 004 created the constraint,
006 widened it, and neither noticed that no call site used any of the values.

So this test derives both sides rather than restating either. The literals come
from the AST of the source, the permitted values from the migration SQL.
Adding a call site with a new event type fails here instead of 500ing at
runtime.

Two ways this guard was itself blind, both fixed here:

* **It read only ``api_compat.py``.** ``onboarding.py`` also calls
  ``_audit_log`` and was invisible to it — so the module carrying the one
  non-atomic writer was also the module outside the vocabulary check. Modules
  are now *discovered* by looking for the call, not listed: a third module
  cannot be added without this guard following it.

* **It only understood literals.** ``onboarding._terminal_transition`` receives
  its ``event_type`` as a parameter, so a literal-only extractor finds nothing
  there and reports success. That is the failure mode this file's own docstring
  warns about — "a guard that misses call sites is worse than no guard because
  it reads as coverage" — reproduced inside the guard. Parameters are now
  resolved one hop back to the callers that supply them, and anything that
  cannot be resolved **fails the run** rather than being quietly skipped.

The second point is the load-bearing one. An extractor that silently returns
less than the truth turns this file into decoration.
"""
from __future__ import annotations

import ast
import re
from pathlib import Path

SRC_DIR = Path(__file__).resolve().parent.parent
MIGRATIONS_DIR = SRC_DIR / "db" / "migrations"

# Undotted types that a call site really does emit. The constraint's other
# undotted values are retained legacy vocabulary nothing writes, but these two
# are live: onboarding.py has emitted them since migration 006 and rows exist
# using them. Renaming them to the dotted convention is a data migration, not a
# tidy-up, so they are named here rather than quietly exempted by a rule.
LIVE_UNDOTTED_EVENT_TYPES = {"onboarding_completed", "onboarding_skipped"}

# The migration that owns the constraint today. When a later migration widens it
# again, point this at that file — the test will then track the newer list.
# Must name the LAST migration that recreates audit_events_event_type_check,
# because that is the one whose vocabulary survives. 010_agent_credentials.sql
# and 011_agent_stunned_event_type.sql both drop-and-recreate that constraint;
# 011 runs second and carries the union of both event sets, so it is the file
# that describes the runtime constraint.
#
# Repointing this line is exactly the wrong instinct when this test goes red
# after a merge: it turns the test green while leaving the database constraint
# missing an event type. Point it at whichever migration runs LAST, and make
# that migration enumerate every type.
CONSTRAINT_MIGRATION = MIGRATIONS_DIR / "021_user_currency_event_type.sql"


EVENT_TYPE_POSITION = 2
"""``_audit_log(executor, tenant_id, event_type, ...)`` — third positional."""


def _source_modules() -> list[Path]:
    """Every non-test module in the app. Discovered, never listed.

    A hardcoded list is how the previous version missed onboarding.py: the
    module was added, the list was not, and nothing said so.
    """
    return sorted(p for p in SRC_DIR.rglob("*.py") if "tests" not in p.parts)


def _called_name(node: ast.Call) -> str | None:
    func = node.func
    return func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", None)


def _argument_for(node: ast.Call, position: int, keyword: str) -> ast.expr | None:
    """The argument at ``position``, whether passed positionally or by name."""
    for kw in node.keywords:
        if kw.arg == keyword:
            return kw.value
    if len(node.args) > position:
        return node.args[position]
    return None


def _enclosing_function(tree: ast.AST, target: ast.Call) -> ast.FunctionDef | ast.AsyncFunctionDef | None:
    best: ast.FunctionDef | ast.AsyncFunctionDef | None = None
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        if node.lineno <= target.lineno <= (node.end_lineno or node.lineno):
            if best is None or node.lineno > best.lineno:
                best = node
    return best


def _parameter_index(function: ast.FunctionDef | ast.AsyncFunctionDef, name: str) -> int | None:
    names = [a.arg for a in function.args.args]
    return names.index(name) if name in names else None


def _resolve_through_callers(
    trees: dict[Path, ast.AST], function_name: str, index: int, keyword: str,
) -> set[str]:
    """Literals that any caller passes into ``function_name``'s parameter.

    One hop, deliberately. ``onboarding._terminal_transition`` takes its
    event_type as an argument and every caller supplies a literal, which is the
    real pattern here. A general dataflow engine would be a second system to
    trust; one hop is enough to be exact about the code that exists, and
    anything deeper is reported unresolved rather than guessed at.
    """
    found: set[str] = set()
    for tree in trees.values():
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call) or _called_name(node) != function_name:
                continue
            argument = _argument_for(node, index, keyword)
            if isinstance(argument, ast.Constant) and isinstance(argument.value, str):
                found.add(argument.value)
    return found


def _caller_expression_for(
    trees: dict[Path, ast.AST], function_name: str, index: int, keyword: str,
) -> ast.expr | None:
    """The expression callers pass into ``function_name``'s parameter.

    ``_resolve_through_callers``'s sibling, returning the AST node instead of a
    string literal. The actor check needs the node: ``principal.actor`` is an
    attribute access, not a constant, so a literal-only resolver reports every
    legitimate call site as unresolvable.

    Returns ``None`` when callers disagree, rather than picking one. Two callers
    passing different things means the resolution is not a fact, and this file's
    rule is that an unresolved value is reported rather than guessed at.
    """
    found: list[ast.expr] = []
    for tree in trees.values():
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call) or _called_name(node) != function_name:
                continue
            argument = _argument_for(node, index, keyword)
            if argument is not None:
                found.append(argument)
    if not found:
        return None
    shapes = {ast.unparse(expression) for expression in found}
    return found[0] if len(shapes) == 1 else None


def _extract_event_types() -> tuple[set[str], list[str]]:
    """Every event type reaching ``_audit_log``, and every one that eluded us.

    Returns ``(resolved, unresolved)``. The second element is the point: a call
    site whose event type cannot be determined is *reported*, not dropped. An
    extractor that silently returns less than the truth reads as coverage while
    providing none — the exact shape of the bug this whole file exists for.
    """
    trees = {path: ast.parse(path.read_text()) for path in _source_modules()}
    resolved: set[str] = set()
    unresolved: list[str] = []

    for path, tree in trees.items():
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call) or _called_name(node) != "_audit_log":
                continue

            argument = _argument_for(node, EVENT_TYPE_POSITION, "event_type")
            where = f"{path.name}:{node.lineno}"

            if isinstance(argument, ast.Constant) and isinstance(argument.value, str):
                resolved.add(argument.value)
                continue

            # Not a literal. If it names a parameter of the enclosing function,
            # the callers of that function are where the literals live.
            if isinstance(argument, ast.Name):
                function = _enclosing_function(tree, node)
                index = _parameter_index(function, argument.id) if function else None
                if function is not None and index is not None:
                    through = _resolve_through_callers(
                        trees, function.name, index, argument.id,
                    )
                    if through:
                        resolved |= through
                        continue

            unresolved.append(where)

    return resolved, unresolved


def _emitted_event_types() -> set[str]:
    resolved, _ = _extract_event_types()
    return resolved


def _permitted_event_types() -> set[str]:
    """The values inside the migration's ``CHECK (event_type IN (...))``."""
    sql = CONSTRAINT_MIGRATION.read_text()
    match = re.search(r"CHECK\s*\(\s*event_type\s+IN\s*\((.*?)\)\s*\)", sql, re.S | re.I)
    assert match is not None, f"no CHECK (event_type IN (...)) found in {CONSTRAINT_MIGRATION.name}"
    return set(re.findall(r"'([^']+)'", match.group(1)))


def test_the_source_emits_event_types_at_all() -> None:
    """Guards the guard: an extractor that finds nothing would pass vacuously."""
    emitted = _emitted_event_types()
    assert len(emitted) >= 10, f"only found {len(emitted)} event types — extractor is probably broken"


def test_the_migration_permits_values_at_all() -> None:
    permitted = _permitted_event_types()
    assert len(permitted) >= 10, f"only parsed {len(permitted)} permitted values — parser is probably broken"


def test_every_emitted_event_type_is_permitted() -> None:
    """The regression guard. This is the bug, stated as an assertion."""
    emitted = _emitted_event_types()
    permitted = _permitted_event_types()
    rejected = sorted(emitted - permitted)
    assert not rejected, (
        f"{len(rejected)} event type(s) written by _audit_log are not permitted by "
        f"{CONSTRAINT_MIGRATION.name}: {rejected}. Every insert of these raises "
        "CheckViolationError at runtime, and because the mutation commits first, "
        "the endpoint persists its change and then returns 500. Add them to the "
        "constraint in a new migration."
    )


def test_emitted_event_types_use_the_dotted_convention() -> None:
    """Most call sites use ``area.action``; keep new ones consistent.

    The two live undotted names are stated explicitly rather than excused by a
    pattern. The previous version of this test asserted that no call site emits
    an undotted type, which was simply untrue — onboarding.py emits two, and
    the test passed only because it could not see that module.
    """
    odd = sorted(
        t for t in _emitted_event_types()
        if "." not in t and t not in LIVE_UNDOTTED_EVENT_TYPES
    )
    assert not odd, (
        f"event types not using the dotted area.action convention: {odd}. "
        f"The only undotted names still written are {sorted(LIVE_UNDOTTED_EVENT_TYPES)}; "
        "the rest of the undotted vocabulary in the constraint is retained "
        "legacy that nothing emits."
    )


def test_every_audit_call_sites_event_type_is_resolvable() -> None:
    """Guards the guard, and is the reason this file was rewritten.

    An ``_audit_log`` call whose event type this extractor cannot determine is
    a hole in every other assertion here: the type is never checked against the
    constraint, so it reaches the database unvalidated and raises there instead.

    Failing loudly is the whole design. The alternative — skipping what it
    cannot parse — is what the previous version did with every parameterised
    call site, and it read as coverage for as long as nobody looked.
    """
    _, unresolved = _extract_event_types()
    assert not unresolved, (
        f"{len(unresolved)} _audit_log call site(s) with an event type this test "
        f"cannot resolve: {unresolved}. Every other assertion in this file is "
        "blind to them, so they reach the CHECK constraint unvalidated. Either "
        "pass a literal, or pass it from a caller one hop away, or extend the "
        "resolver -- but do not leave it unresolved."
    )


ACTOR_POSITION = 5
"""``_audit_log(executor, tenant_id, event_type, agent_id, agent_name, actor, ...)``."""


# Call sites known to record a non-Principal actor, keyed on module and the
# resolved value. Keyed on the VALUE, not just the location: changing which
# fabricated name a site records is a new decision and should fail here rather
# than inherit an exemption written about a different string.
#
# ``test_the_actor_exemptions_are_all_still_needed`` deletes these for you by
# going red the moment a site stops needing one.
#: Empty, and it should stay that way.
#:
#: It held one entry: onboarding.py passing `actor=ACTOR` where
#: `ACTOR = "onboarding-api"`, so every `onboarding_completed` and
#: `onboarding_skipped` row named a service rather than the person. That
#: mattered more than the count suggested -- `tenant_onboarding` holds only
#: terminal state, so the audit row was the sole durable evidence the
#: transition happened, and it could not name anybody.
#:
#: Fixed 2026-08-14: both routes take `authenticated_principal` and pass
#: `principal.actor`. `test_the_actor_exemptions_are_all_still_needed` named
#: the entry the moment it stopped being true and refused to pass until it was
#: deleted -- which is the property this dict exists for. A declared defect
#: that survives its own fix is worse than an undeclared one, because it goes
#: on covering whatever moves into its place.
ACTOR_DEFECTS_PENDING_FIX: dict[tuple[str, str], str] = {}


def test_no_audit_call_site_hardcodes_its_actor() -> None:
    """The actor must come from the caller's token, never from a literal.

    ``Principal.actor``'s docstring says an unattributable record is "worthless
    as evidence, so the value has to come from the token rather than from a
    literal in the handler", and that substituting one "would put a fabricated
    name in an audit column". Thirty-four occurrences of "demo-actor" said
    otherwise -- including in two handlers that already held the principal in
    scope for a NOT NULL business column and passed the literal to the audit
    row three lines later.

    Stated as a test because it is not visible in review: each individual
    literal reads as a reasonable demo placeholder. Only the aggregate shows
    that a bank's first question -- who did this -- had one answer for every
    row in the product.

    THE HOLE THIS TEST HAD, AND WHAT WAS SITTING IN IT
    --------------------------------------------------
    The check was ``isinstance(actor, ast.Constant)``: a literal *at the call
    site*. ``onboarding.py`` passes ``actor=ACTOR``, and ``ACTOR`` is
    ``"onboarding-api"``, a module constant declared at line 59. That is an
    ``ast.Name``, so this test walked straight past it and reported success.
    Moving one literal behind a constant defeated the guard entirely -- and
    nobody did that to evade anything, it is just how a tidy person writes it.

    So the audit trail said a *service* completed onboarding. The human who
    clicked the button was authenticated, resolved, and cached by FastAPI:
    both handlers depend on ``authenticated_tenant``, which is
    ``authenticated_principal``'s own wrapper, so the Principal was in scope
    and thrown away. The record names the thing that wrote the row instead of
    the thing that took the decision, which is the one question the row exists
    to answer.

    The rewrite therefore asserts on the RESOLVED value, not on the syntactic
    category of the expression. A name is followed to its assignment -- local,
    then enclosing-parameter, then module scope -- and the result must be an
    attribute access on a Principal. Anything that cannot be resolved FAILS
    rather than passing, for the reason this file's own docstring gives about
    event types: an extractor that silently returns less than the truth reads
    as coverage while providing none.
    """
    trees = {path: ast.parse(path.read_text()) for path in _source_modules()}
    hardcoded: list[str] = []
    unresolved: list[str] = []

    for path, tree in trees.items():
        module_constants = {
            target.id: node.value
            for node in tree.body
            if isinstance(node, ast.Assign)
            for target in node.targets
            if isinstance(target, ast.Name)
        }

        for node in ast.walk(tree):
            if not isinstance(node, ast.Call) or _called_name(node) != "_audit_log":
                continue
            actor = _argument_for(node, ACTOR_POSITION, "actor")
            where = f"{path.name}:{node.lineno}"

            # Follow a bare name one hop, in the order the shapes actually
            # occur in this tree:
            #
            #   1. a local assignment in the enclosing handler
            #      (`actor = principal.actor` -- patch_user_preferences),
            #   2. a parameter of the enclosing helper, resolved back to what
            #      its callers pass (`_db_policy_scan(..., actor)` -- the same
            #      one-hop trick _extract_event_types uses, and needed for the
            #      same reason: a helper that receives the value looks like a
            #      literal-free call site while the literal sits in its caller),
            #   3. a module constant (`ACTOR = "onboarding-api"`).
            #
            # Only the first two can yield a Principal.
            if isinstance(actor, ast.Name):
                function = _enclosing_function(tree, node)
                resolved = None
                if function is not None:
                    for statement in ast.walk(function):
                        if isinstance(statement, ast.Assign) and any(
                            isinstance(t, ast.Name) and t.id == actor.id
                            for t in statement.targets
                        ):
                            resolved = statement.value
                            break
                    if resolved is None:
                        index = _parameter_index(function, actor.id)
                        if index is not None:
                            resolved = _caller_expression_for(
                                trees, function.name, index, actor.id,
                            )
                actor = resolved if resolved is not None else module_constants.get(actor.id, actor)

            if isinstance(actor, ast.Constant):
                if (path.name, actor.value) not in ACTOR_DEFECTS_PENDING_FIX:
                    hardcoded.append(f"{where} -> {actor.value!r}")
            elif isinstance(actor, ast.Attribute) and actor.attr == "actor":
                continue  # principal.actor -- the token's own identity
            else:
                unresolved.append(
                    f"{where} -> {ast.unparse(actor) if actor is not None else 'MISSING'}"
                )

    assert not hardcoded, (
        f"{len(hardcoded)} _audit_log call site(s) pass a hardcoded actor: "
        f"{hardcoded}. Take it from the request's Principal -- "
        "authenticated_principal is authenticated_tenant's own dependency, so "
        "a handler that only has the tenant can swap to it without changing "
        "which tenant it resolves. A module constant is a hardcoded actor with "
        "a longer name; naming the service that wrote the row does not answer "
        "who took the decision."
    )
    assert not unresolved, (
        f"{len(unresolved)} _audit_log call site(s) pass an actor this test "
        f"cannot resolve to principal.actor: {unresolved}. Reported rather than "
        "skipped -- an unresolved actor is invisible to the assertion above, so "
        "skipping it would turn this test into decoration. Pass principal.actor "
        "directly, assign it from the Principal in the handler, or extend the "
        "resolver."
    )


def test_the_actor_exemptions_are_all_still_needed() -> None:
    """An exemption that outlives its defect covers whatever moves in next.

    Asserted by re-deriving the resolved actor values rather than by trusting
    the dict, so a fix that lands elsewhere forces the entry out of this file.
    """
    live: set[tuple[str, str]] = set()
    for path in _source_modules():
        tree = ast.parse(path.read_text())
        module_constants = {
            target.id: node.value
            for node in tree.body
            if isinstance(node, ast.Assign)
            for target in node.targets
            if isinstance(target, ast.Name)
        }
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call) or _called_name(node) != "_audit_log":
                continue
            actor = _argument_for(node, ACTOR_POSITION, "actor")
            if isinstance(actor, ast.Name):
                actor = module_constants.get(actor.id, actor)
            if isinstance(actor, ast.Constant) and isinstance(actor.value, str):
                live.add((path.name, actor.value))

    stale = sorted(str(key) for key in ACTOR_DEFECTS_PENDING_FIX if key not in live)
    assert not stale, (
        f"ACTOR_DEFECTS_PENDING_FIX names {len(stale)} call site(s) that no "
        f"longer record a fabricated actor: {stale}. Delete them."
    )


def test_the_extractor_sees_more_than_one_module() -> None:
    """The specific blindness that motivated this rewrite.

    Reading only api_compat.py silently excluded onboarding.py's two event
    types. Asserting on a known cross-module value keeps the discovery honest:
    if module scanning regresses to a single file, this goes red.
    """
    emitted = _emitted_event_types()
    assert "onboarding_completed" in emitted, (
        "onboarding.py's event types are missing -- the extractor is reading "
        "too few modules, or stopped resolving parameters"
    )
    assert "agent.stunned" in emitted, "api_compat.py's event types are missing"
