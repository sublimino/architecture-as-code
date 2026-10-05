"""Unit tests for routes.py — the derivation of the explorable application surface.

Run: python3 -m pytest scripts/jev-test-bot/test_routes.py -q

The load-bearing test is `test_every_static_route_in_app_tsx_is_derived`. It
reads the REAL `App.tsx` rather than a fixture, so adding a page to the
dashboard without teaching the bot about it fails here. That is the whole
point: a new page must not be able to go silently unexplored.

The fixture-driven tests cover the parsing shapes that actually occur in
`App.tsx` and the ones a future edit might introduce:

  * `path="/agents"`              — the common form
  * `path={'/demos/agentmaxxing'}`— the brace+quote form (lines 457-458 today)
  * `path="/agents/:id"`          — parametrised, needs a representative value
  * `path="/demos/agentmaxxing/*"`— splat, whose addressable base is the parent
  * `path="*"`                    — the catch-all, which is not a surface
"""

import os
import re
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import routes  # noqa: E402


REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
APP_TSX = os.path.join(
    REPO_ROOT, "d2-signalloom", "apps", "dashboard-signalloom", "src", "App.tsx"
)


FIXTURE = """
              <Routes>
                <Route path="/login" element={<LoginPage />} />
                <Route path="/callback" element={<CallbackPage />} />
                <Route path="/" element={<Navigate to="/agents" replace />} />
                <Route path="/agents" element={<ProtectedRoute><AgentsPage /></ProtectedRoute>} />
                <Route path="/agents/:id" element={<ProtectedRoute><AgentDetailPage /></ProtectedRoute>} />
                <Route path={'/demos/agentmaxxing'} element={<ProtectedRoute><Demo /></ProtectedRoute>} />
                <Route path={'/demos/agentmaxxing/*'} element={<ProtectedRoute><Demo /></ProtectedRoute>} />
                <Route path="/help/connectors/:provider" element={<ProtectedRoute><Help /></ProtectedRoute>} />
                <Route path="*" element={<Navigate to="/agents" replace />} />
              </Routes>
"""


# ── Parsing ────────────────────────────────────────────────────────────────

def test_parses_both_quote_and_brace_attribute_forms():
    raw = routes.parse_route_paths(FIXTURE)
    assert "/agents" in raw, "double-quoted path form not parsed"
    assert "/demos/agentmaxxing" in raw, "brace+quote path form not parsed"
    assert "/demos/agentmaxxing/*" in raw


def test_parsing_preserves_declaration_order_and_dedupes():
    raw = routes.parse_route_paths(FIXTURE + FIXTURE)
    assert raw == routes.parse_route_paths(FIXTURE), "duplicate declarations must collapse"
    assert raw.index("/login") < raw.index("/agents") < raw.index("/agents/:id")


def test_classifiers():
    assert routes.is_static("/agents")
    assert not routes.is_static("/agents/:id"), "a parametrised path is not static"
    assert not routes.is_static("*")
    assert not routes.is_static("/demos/agentmaxxing/*")
    assert routes.is_auth_only("/login")
    assert routes.is_auth_only("/callback")
    assert not routes.is_auth_only("/agents")


# ── Derivation ─────────────────────────────────────────────────────────────

def test_auth_only_routes_are_excluded():
    derived = routes.derive_routes(FIXTURE)
    assert "/login" not in derived
    assert "/callback" not in derived


def test_parametrised_routes_get_a_representative_value():
    derived = routes.derive_routes(FIXTURE)
    assert "/agents/example" in derived, "/agents/:id must resolve to a concrete path"
    assert "/help/connectors/github" in derived
    assert not any(":" in route for route in derived), f"unsubstituted parameter in {derived}"


def test_catch_all_is_not_a_surface_but_a_splat_base_is():
    derived = routes.derive_routes(FIXTURE)
    assert "*" not in derived
    assert not any(route.endswith("*") for route in derived)
    # `/demos/agentmaxxing/*` collapses onto its addressable parent, which the
    # sibling non-splat route already declares — so exactly one entry survives.
    assert derived.count("/demos/agentmaxxing") == 1


def test_every_derived_route_is_an_absolute_path():
    for route in routes.derive_routes(FIXTURE):
        assert route.startswith("/"), route


def test_unknown_parameter_falls_back_rather_than_dropping_the_route():
    """An unmapped parameter must not silently remove a page from the surface."""
    src = '<Route path="/widgets/:widgetId" element={<W />} />'
    derived = routes.derive_routes(src)
    assert derived == ["/widgets/" + routes.DEFAULT_PARAM_VALUE]


# ── The coverage invariant, against the real App.tsx ───────────────────────

@pytest.mark.skipif(not os.path.exists(APP_TSX), reason="App.tsx not present in this tree")
def test_every_static_route_in_app_tsx_is_derived():
    with open(APP_TSX, encoding="utf-8") as handle:
        src = handle.read()

    raw = routes.parse_route_paths(src)
    assert len(raw) > 20, f"suspiciously few routes parsed ({len(raw)}) — parser likely broken"

    derived = set(routes.derive_routes(src))
    expected = [
        path for path in raw if routes.is_static(path) and not routes.is_auth_only(path)
    ]
    assert expected, "no static routes found — parser broken"

    missing = [path for path in expected if path not in derived]
    assert not missing, (
        "static routes declared in App.tsx but absent from the derived surface: "
        f"{missing}. A new page must not be silently unexplored — either add it "
        "or declare it an exclusion in routes.py with a reason."
    )


@pytest.mark.skipif(not os.path.exists(APP_TSX), reason="App.tsx not present in this tree")
def test_real_surface_has_no_unsubstituted_parameters_or_splats():
    with open(APP_TSX, encoding="utf-8") as handle:
        src = handle.read()
    for route in routes.derive_routes(src):
        assert ":" not in route, f"unsubstituted parameter: {route}"
        assert "*" not in route, f"splat leaked into the surface: {route}"
        assert route.startswith("/"), route


@pytest.mark.skipif(not os.path.exists(APP_TSX), reason="App.tsx not present in this tree")
def test_every_parameter_in_app_tsx_has_a_mapped_representative_value():
    """A fallback keeps coverage honest, but a named map keeps it meaningful.

    This test does not fail the build for an unmapped parameter — it reports
    them, so the fallback never quietly becomes the norm for every page.
    """
    with open(APP_TSX, encoding="utf-8") as handle:
        src = handle.read()
    params = set()
    for path in routes.parse_route_paths(src):
        params.update(re.findall(r":([A-Za-z0-9_]+)", path))
    unmapped = sorted(p for p in params if p not in routes.PARAM_VALUES)
    assert not unmapped, (
        f"route parameters with no representative value in routes.PARAM_VALUES: {unmapped}"
    )
