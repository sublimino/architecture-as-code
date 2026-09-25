# ==============================================================================
# d2-signalloom/apps/fe-signalloom/src/tests/test_environment_teardown.py
# SLED-P3-1: Stage 1 (ingress route severing) and Stage 2 (Tailscale eviction).
#
# Stage 1 runs against a stateful fake kubectl (a real executable holding its
# routes in a JSON file), so the subprocess, timeout and re-list paths all run
# for real. Stage 2 runs the real scripts/eap/tailscale-eap-env.sh in mock mode.
# ==============================================================================
import http.server
import json
import os
import subprocess
import sys
import textwrap
import threading
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

import eap_tenancy
from conftest import EAP_ALICE, EAP_OPERATOR, EAP_TENANT_A, EAPClient

EAP_AUTHENTICATED = True

import environment_teardown as td
from environment_lifecycle import EnvironmentLifecycleState, GLOBAL_LIFECYCLE_MANAGER, LifecycleManager
from environment_teardown import (
    DEFAULT_TAILSCALE_SCRIPT,
    FailureTracker,
    StageOutcome,
    TeardownStage,
    evict_tailscale_node,
    resolve_repo_root,
    run_bounded,
    run_network_teardown,
    run_ordered_teardown,
    sever_ingress_routes,
)

from environment_routing import derive_customer_hash
KUSARI = "kusari"
H = derive_customer_hash(KUSARI)
OTHER = derive_customer_hash("other-tenant")
SRC = Path(__file__).resolve().parents[1]

FAKE_KUBECTL = textwrap.dedent(r'''
    #!/usr/bin/env python3
    import json, os, subprocess, sys, time
    state = os.environ["FAKE_KUBE_STATE"]
    mode = os.environ.get("FAKE_KUBECTL_MODE", "")
    args = sys.argv[1:]
    if mode == "hang":
        # A grandchild holding stdout open: only a process-group kill ends this.
        child = subprocess.Popen(["sleep", "30"])
        open(state + ".grandchild", "w").write(str(child.pid))
        time.sleep(30)
    routes = json.load(open(state))
    ns = args[args.index("-n") + 1] if "-n" in args else "default"
    if args[:2] == ["delete", "namespace"]:
        if mode == "delete-fails":
            print("error: admission denied", file=sys.stderr); sys.exit(1)
        print(f"namespace/{args[2]} deleted"); sys.exit(0)
    if args[:2] == ["get", "httproute"]:
        if mode == "get-fails":
            print("error: forbidden", file=sys.stderr); sys.exit(1)
        items = [r for r in routes if r["metadata"]["namespace"] == ns]
        print(json.dumps({"items": items})); sys.exit(0)
    if args[:2] == ["delete", "httproute"]:
        name = args[2]
        if mode == "delete-fails":
            print("error: admission denied", file=sys.stderr); sys.exit(1)
        if mode != "sticky":
            routes = [r for r in routes if not (r["metadata"]["name"] == name and r["metadata"]["namespace"] == ns)]
            json.dump(routes, open(state, "w"))
        print(f"httproute.gateway.networking.k8s.io/{name} deleted"); sys.exit(0)
    print("unsupported: " + " ".join(args), file=sys.stderr); sys.exit(2)
''').lstrip()


def _route(name, ns="fe-signalloom", label=None, hosts=()):
    meta = {"name": name, "namespace": ns, "labels": {}}
    if label:
        meta["labels"]["signalloom.io/eap-hash"] = label
    return {"metadata": meta, "spec": {"hostnames": list(hosts)}}


@pytest.fixture
def kube(tmp_path, monkeypatch):
    """Fake cluster: H has a labelled route and an unlabelled hostname-only route; OTHER has one."""
    kbin = tmp_path / "kubectl"
    kbin.write_text(FAKE_KUBECTL)
    kbin.chmod(0o755)
    state = tmp_path / "routes.json"
    state.write_text(json.dumps([
        _route(f"eap-route-{H}", label=H, hosts=[f"sl-eap-{H}.tailscale"]),
        _route("hand-rolled-route", hosts=[f"sl-eap-{H}.ts.net"]),
        _route(f"eap-route-{OTHER}", label=OTHER, hosts=[f"sl-eap-{OTHER}.tailscale"]),
        _route(f"eap-route-{H}", ns="elsewhere", label=H),
    ]))
    monkeypatch.setenv("FAKE_KUBE_STATE", str(state))
    monkeypatch.setenv("SIGNALLOOM_KUBECTL", str(kbin))
    monkeypatch.delenv("FAKE_KUBECTL_MODE", raising=False)
    monkeypatch.delenv("SIGNALLOOM_EAP_ROUTE_NAMESPACE", raising=False)

    def names(ns="fe-signalloom"):
        return sorted(r["metadata"]["name"] for r in json.loads(state.read_text()) if r["metadata"]["namespace"] == ns)
    return names


@pytest.fixture
def tsmock(tmp_path, monkeypatch):
    """Isolated tailscale mock dir with H provisioned, served and funnelled via the real script."""
    mdir = tmp_path / "tailscale-eap-mock"
    monkeypatch.setenv("TAILSCALE_MOCK_DIR", str(mdir))
    monkeypatch.delenv("SIGNALLOOM_EAP_TAILSCALE_LIVE", raising=False)
    monkeypatch.delenv("SIGNALLOOM_TAILSCALE_EAP_SCRIPT", raising=False)
    env = {**os.environ, "TAILSCALE_MOCK": "1", "TAILSCALE_MOCK_DIR": str(mdir)}
    for cmd in ("provision", "serve", "funnel"):
        subprocess.run(["bash", str(DEFAULT_TAILSCALE_SCRIPT), cmd, KUSARI], env=env, check=True,
                       capture_output=True, stdin=subprocess.DEVNULL, timeout=10)
    node = mdir / f"sl-eap-{H}"
    assert (node / "serve.json").is_file() and (node / "funnel.json").is_file()
    return node


# ------------------------------------------------------------------------------
# Stage 1
# ------------------------------------------------------------------------------

def test_stage1_removes_label_and_hostname_matches_only(kube):
    res = sever_ingress_routes(H)
    assert res.outcome is StageOutcome.COMPLETED, res.detail
    assert res.removed == ["eap-route-" + H, "hand-rolled-route"]
    assert kube() == [f"eap-route-{OTHER}"]            # the other customer is untouched
    assert kube("elsewhere") == [f"eap-route-{H}"]     # scoped to the configured namespace


def test_stage1_is_idempotent(kube):
    assert sever_ingress_routes(H).outcome is StageOutcome.COMPLETED
    again = sever_ingress_routes(H)
    assert again.outcome is StageOutcome.ALREADY_ABSENT and again.removed == []
    assert again.outcome.succeeded


def test_stage1_namespace_override(kube, monkeypatch):
    monkeypatch.setenv("SIGNALLOOM_EAP_ROUTE_NAMESPACE", "elsewhere")
    assert sever_ingress_routes(H).removed == [f"eap-route-{H}"]
    assert kube("elsewhere") == [] and len(kube()) == 3


def test_stage1_missing_kubectl_fails_gracefully(monkeypatch):
    monkeypatch.setenv("SIGNALLOOM_KUBECTL", "/nonexistent/kubectl")
    res = sever_ingress_routes(H)
    assert res.outcome is StageOutcome.FAILED and "not found" in res.detail


@pytest.mark.parametrize("mode,needle", [("get-fails", "forbidden"), ("delete-fails", "admission denied"),
                                         ("sticky", "still present")])
def test_stage1_reports_cluster_failures(kube, monkeypatch, mode, needle):
    monkeypatch.setenv("FAKE_KUBECTL_MODE", mode)
    res = sever_ingress_routes(H)
    assert res.outcome is StageOutcome.FAILED and needle in res.detail


def test_stage1_timeout_kills_the_whole_process_group(kube, monkeypatch, tmp_path):
    monkeypatch.setenv("FAKE_KUBECTL_MODE", "hang")
    t0 = time.monotonic()
    res = sever_ingress_routes(H, timeout=1.0)
    elapsed = time.monotonic() - t0
    assert res.outcome is StageOutcome.FAILED and "timeout" in res.detail
    assert elapsed < 3.0, f"stage overran its budget: {elapsed:.2f}s"
    gpid = int((tmp_path / "routes.json.grandchild").read_text())
    time.sleep(0.1)
    alive = Path(f"/proc/{gpid}").exists() and "Z" not in Path(f"/proc/{gpid}/stat").read_text().split()[2]
    assert not alive, "grandchild survived the stage timeout"


def test_default_stage_budget_is_five_seconds():
    assert td.STAGE_TIMEOUT_SECONDS == 5.0


class _Handler(http.server.BaseHTTPRequestHandler):
    code = 404

    def do_GET(self):
        self.send_response(self.code)
        self.end_headers()

    def log_message(self, *a):
        pass


@pytest.fixture
def http_server():
    servers = []

    def start(code):
        handler = type("H", (_Handler,), {"code": code})
        srv = http.server.HTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        servers.append(srv)
        return f"http://127.0.0.1:{srv.server_address[1]}/"
    yield start
    for s in servers:
        s.shutdown()
        s.server_close()


@pytest.mark.parametrize("code", [404, 503])
def test_stage1_probe_accepts_404_and_503(kube, http_server, code):
    res = sever_ingress_routes(H, probe_url=http_server(code))
    assert res.outcome is StageOutcome.COMPLETED and f"-> {code}" in res.detail


def test_stage1_probe_fails_if_domain_still_serves(kube, http_server):
    res = sever_ingress_routes(H, probe_url=http_server(200))
    assert res.outcome is StageOutcome.FAILED and "still answers HTTP 200" in res.detail


def test_probe_unreachable_is_not_success():
    assert td.probe_customer_domain("http://127.0.0.1:1/", timeout=0.5)["severed"] is None


def test_run_bounded_closes_its_pipes():
    fd_dir = Path("/proc/self/fd")
    before = len(list(fd_dir.iterdir()))
    for _ in range(20):
        run_bounded(["true"], time.monotonic() + 5)
    assert len(list(fd_dir.iterdir())) <= before


def test_run_bounded_never_waits_on_stdin():
    res = run_bounded(["bash", "-c", "read -r line; echo got:$?"], time.monotonic() + 2)
    assert res.stdout.strip() == "got:1"   # EOF from /dev/null, not a prompt


# ------------------------------------------------------------------------------
# Stage 2 — real tailscale-eap-env.sh subprocess, mock mode
# ------------------------------------------------------------------------------

def test_stage2_evicts_node_and_purges_mock_state(tsmock):
    res = evict_tailscale_node(H)
    assert res.outcome is StageOutcome.COMPLETED, res.detail
    assert res.mode == "mock" and res.removed == [f"sl-eap-{H}"]
    assert not tsmock.exists(), "serve/funnel mock state survived eviction"


def test_stage2_is_idempotent_and_handles_absent_node(tsmock):
    evict_tailscale_node(H)
    again = evict_tailscale_node(H)
    assert again.outcome is StageOutcome.ALREADY_ABSENT and again.outcome.succeeded
    never = evict_tailscale_node(OTHER)
    assert never.outcome is StageOutcome.ALREADY_ABSENT


def test_stage2_only_evicts_the_named_customer(tsmock, monkeypatch):
    env = {**os.environ, "TAILSCALE_MOCK": "1"}
    subprocess.run(["bash", str(DEFAULT_TAILSCALE_SCRIPT), "provision", "other-tenant"], env=env, check=True,
                   capture_output=True, stdin=subprocess.DEVNULL, timeout=10)
    other = tsmock.parent / f"sl-eap-{OTHER}"
    assert other.is_dir()
    evict_tailscale_node(H)
    assert other.is_dir() and not tsmock.exists()


def test_stage2_defaults_to_mock_even_with_tailscale_installed(tmp_path, monkeypatch):
    """Live mode resets serve/funnel and logs out the whole node, so it must be opt-in."""
    spy = tmp_path / "spy.sh"
    spy.write_text('#!/usr/bin/env bash\necho "TAILSCALE_MOCK=$TAILSCALE_MOCK args=$*"\n')
    monkeypatch.delenv("SIGNALLOOM_EAP_TAILSCALE_LIVE", raising=False)
    monkeypatch.setenv("TAILSCALE_MOCK", "0")   # an ambient 0 must not leak through
    res = evict_tailscale_node(H, script=str(spy), mock_dir=str(tmp_path / "m"))
    assert res.mode == "mock" and f"TAILSCALE_MOCK=1 args=teardown --hash {H}" in res.detail
    monkeypatch.setenv("SIGNALLOOM_EAP_TAILSCALE_LIVE", "1")
    live = evict_tailscale_node(H, script=str(spy))
    assert live.mode == "live" and "TAILSCALE_MOCK=0" in live.detail


def test_stage2_missing_script_and_nonzero_exit(tmp_path, monkeypatch):
    monkeypatch.delenv("SIGNALLOOM_EAP_TAILSCALE_LIVE", raising=False)
    assert evict_tailscale_node(H, script=str(tmp_path / "nope.sh")).outcome is StageOutcome.FAILED
    bad = tmp_path / "bad.sh"
    bad.write_text("#!/usr/bin/env bash\necho boom >&2\nexit 3\n")
    res = evict_tailscale_node(H, script=str(bad), mock_dir=str(tmp_path / "m"))
    assert res.outcome is StageOutcome.FAILED and "rc=3" in res.detail and "boom" in res.detail


def test_stage2_timeout_is_bounded(tmp_path, monkeypatch):
    monkeypatch.delenv("SIGNALLOOM_EAP_TAILSCALE_LIVE", raising=False)
    slow = tmp_path / "slow.sh"
    slow.write_text("#!/usr/bin/env bash\nsleep 30 &\nsleep 30\n")
    t0 = time.monotonic()
    res = evict_tailscale_node(H, script=str(slow), timeout=1.0, mock_dir=str(tmp_path / "m"))
    assert res.outcome is StageOutcome.FAILED and "timeout" in res.detail
    assert time.monotonic() - t0 < 3.0


@pytest.mark.parametrize("bad", ["", "A0314BE", "a0314beg", "../../etc", f"{H}; rm -rf /"])
def test_helpers_reject_malformed_hashes(bad):
    with pytest.raises(ValueError):
        sever_ingress_routes(bad)
    with pytest.raises(ValueError):
        evict_tailscale_node(bad)


# ------------------------------------------------------------------------------
# Pipeline, stage metadata, audit, alerting
# ------------------------------------------------------------------------------

def _draining_manager():
    mgr = LifecycleManager()
    mgr.register_environment(KUSARI)
    mgr.transition_state(H, EnvironmentLifecycleState.ACTIVE)
    mgr.transition_state(H, EnvironmentLifecycleState.DRAINING, reason="ttl_expired")
    eap_tenancy.GLOBAL_TENANT_OWNERSHIP.claim(H, EAP_TENANT_A)
    return mgr


def test_pipeline_records_both_stages_and_emits_audit(kube, tsmock):
    mgr, events = _draining_manager(), []
    report = run_network_teardown(H, manager=mgr, audit_sink=events.append, failure_tracker=FailureTracker())
    assert report.ok and report.stages_completed == ["drain_routes", "evict_tailscale"]
    assert mgr.get_lifecycle(H).teardown_stages_completed == ["drain_routes", "evict_tailscale"]
    assert [e["event_type"] for e in events] == ["eap.teardown.drain_routes", "eap.teardown.evict_tailscale"]
    required = {"event_id", "timestamp", "customer_hash", "company_name", "previous_state",
                "current_state", "trigger_reason", "operator_or_system_id"}
    for e in events:
        assert required <= set(e)
        assert e["customer_hash"] == H and e["company_name"] == KUSARI
        assert e["previous_state"] == "draining" and e["operator_or_system_id"] == td.SYSTEM_ACTOR
    assert len({e["event_id"] for e in events}) == 2


def test_pipeline_rerun_skips_recorded_stages(kube, tsmock):
    mgr = _draining_manager()
    run_network_teardown(H, manager=mgr, audit_sink=lambda e: None, failure_tracker=FailureTracker())
    again = run_network_teardown(H, manager=mgr, audit_sink=lambda e: None, failure_tracker=FailureTracker())
    assert again.ok and again.results == []
    assert mgr.get_lifecycle(H).teardown_stages_completed == ["drain_routes", "evict_tailscale"]


def test_stage1_failure_blocks_stage2_and_records_nothing(kube, tsmock, monkeypatch):
    monkeypatch.setenv("FAKE_KUBECTL_MODE", "delete-fails")
    mgr, events = _draining_manager(), []
    report = run_network_teardown(H, manager=mgr, audit_sink=events.append, failure_tracker=FailureTracker())
    assert not report.ok and [r.stage for r in report.results] == [TeardownStage.DRAIN_ROUTES]
    assert tsmock.exists(), "Stage 2 ran while ingress could still route traffic"
    assert mgr.get_lifecycle(H).teardown_stages_completed == []
    assert events[0]["event_type"] == "eap.teardown.stage_failed"
    # Retry after the fault clears resumes and completes both stages.
    monkeypatch.delenv("FAKE_KUBECTL_MODE")
    assert run_network_teardown(H, manager=mgr, audit_sink=events.append, failure_tracker=FailureTracker()).ok


def test_resume_from_stage2_after_partial_teardown(kube, tsmock, monkeypatch):
    mgr = _draining_manager()
    monkeypatch.setenv("SIGNALLOOM_TAILSCALE_EAP_SCRIPT", "/nonexistent.sh")
    first = run_network_teardown(H, manager=mgr, audit_sink=lambda e: None, failure_tracker=FailureTracker())
    assert first.stages_completed == ["drain_routes"] and not first.ok
    monkeypatch.delenv("SIGNALLOOM_TAILSCALE_EAP_SCRIPT")
    second = run_network_teardown(H, manager=mgr, audit_sink=lambda e: None, failure_tracker=FailureTracker())
    assert [r.stage for r in second.results] == [TeardownStage.EVICT_TAILSCALE] and second.ok


def test_alert_fires_on_repeated_failure_and_resets_on_success(kube, monkeypatch):
    monkeypatch.setenv("FAKE_KUBECTL_MODE", "get-fails")
    tracker, events = FailureTracker(threshold=3), []
    for _ in range(3):
        run_network_teardown(H, audit_sink=events.append, failure_tracker=tracker)
    alerts = [e for e in events if e["event_type"] == "eap.teardown.alert"]
    assert len(alerts) == 1 and alerts[0]["consecutive_failures"] == 3
    monkeypatch.delenv("FAKE_KUBECTL_MODE")
    run_network_teardown(H, stages=[TeardownStage.DRAIN_ROUTES], audit_sink=events.append, failure_tracker=tracker)
    assert tracker.record(H, TeardownStage.DRAIN_ROUTES, False) == 1


def test_record_teardown_stage_is_idempotent_and_404s_unknown():
    mgr = _draining_manager()
    mgr.record_teardown_stage(H, "drain_routes")
    rec = mgr.record_teardown_stage(H, "drain_routes")
    assert rec.teardown_stages_completed == ["drain_routes"]
    assert rec.state is EnvironmentLifecycleState.DRAINING and rec.reap_reason == "ttl_expired"
    with pytest.raises(Exception) as exc:
        mgr.record_teardown_stage("deadbeef", "drain_routes")
    assert getattr(exc.value, "status_code", None) == 404


# ------------------------------------------------------------------------------
# API
# ------------------------------------------------------------------------------

@pytest.fixture
def api(kube, tsmock):
    from main import app
    saved = dict(GLOBAL_LIFECYCLE_MANAGER._records)
    GLOBAL_LIFECYCLE_MANAGER._records.clear()
    eap_tenancy.GLOBAL_TENANT_OWNERSHIP.claim(H, EAP_TENANT_A)
    yield EAPClient(app, EAP_ALICE)
    GLOBAL_LIFECYCLE_MANAGER._records.clear()
    GLOBAL_LIFECYCLE_MANAGER._records.update(saved)


def test_api_refuses_teardown_of_active_environment(api, tsmock):
    GLOBAL_LIFECYCLE_MANAGER.register_environment(KUSARI)
    GLOBAL_LIFECYCLE_MANAGER.transition_state(H, EnvironmentLifecycleState.ACTIVE)
    r = api.post(f"/api/v1/eap/lifecycle/environments/{H}/teardown/network")
    assert r.status_code == 409 and tsmock.exists()


def test_api_tears_down_draining_environment(api, kube, tsmock):
    GLOBAL_LIFECYCLE_MANAGER.register_environment(KUSARI)
    GLOBAL_LIFECYCLE_MANAGER.transition_state(H, EnvironmentLifecycleState.DRAINING, reason="idle_timeout")
    r = api.post(f"/api/v1/eap/lifecycle/environments/{H}/teardown/network")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["ok"] and body["stages_completed"] == ["drain_routes", "evict_tailscale"]
    got = api.get(f"/api/v1/eap/lifecycle/environments/{H}").json()
    assert got["teardown_stages_completed"] == ["drain_routes", "evict_tailscale"]
    assert kube() == [f"eap-route-{OTHER}"] and not tsmock.exists()


def test_api_unknown_and_malformed_hash(api):
    assert api.post("/api/v1/eap/lifecycle/environments/deadbeef/teardown/network").status_code == 404
    assert api.post("/api/v1/eap/lifecycle/environments/NOT-HEX!/teardown/network").status_code == 422


# ------------------------------------------------------------------------------
# CLI — flags, exit codes, environment handling
# ------------------------------------------------------------------------------

def _cli(*args, env=None):
    return subprocess.run([sys.executable, str(SRC / "environment_teardown.py"), *args],
                          cwd=SRC, env=env or dict(os.environ), capture_output=True, text=True,
                          stdin=subprocess.DEVNULL, timeout=30)


def test_cli_full_teardown_json(kube, tsmock):
    p = _cli("teardown", "--hash", H, "--json")
    assert p.returncode == 0, p.stderr
    out = json.loads(p.stdout)
    assert out["ok"] and out["stages_completed"] == ["drain_routes", "evict_tailscale"]
    assert [e["event_type"] for e in out["audit_events"]] == \
        ["eap.teardown.drain_routes", "eap.teardown.evict_tailscale"]
    assert out["audit_events"][0]["trigger_reason"] == "operator_cli"
    assert not tsmock.exists()


def test_cli_company_derives_canonical_hash(kube, tsmock):
    p = _cli("teardown", "--company", "Kusari", "--stages", "tailscale", "--json")
    assert p.returncode == 0, p.stderr
    assert json.loads(p.stdout)["customer_hash"] == H and not tsmock.exists()


def test_cli_stage_failure_exits_1(kube, tsmock):
    env = {**os.environ, "FAKE_KUBECTL_MODE": "delete-fails"}
    p = _cli("teardown", "--hash", H, env=env)
    assert p.returncode == 1 and "failed" in p.stdout and tsmock.exists()


@pytest.mark.parametrize("args", [
    ("teardown",),
    ("teardown", "--hash", "XYZ"),
    ("teardown", "--hash", H, "--company", KUSARI),
    ("teardown", "--hash", H, "--stages", "dns"),
    ("teardown", "--hash", H, "--timeout", "0"),
])
def test_cli_usage_errors_exit_2(args):
    assert _cli(*args).returncode == 2


def test_cli_namespace_env_and_flag(kube, tsmock):
    env = {**os.environ, "SIGNALLOOM_EAP_ROUTE_NAMESPACE": "elsewhere"}
    p = _cli("teardown", "--hash", H, "--stages", "ingress", "--json", env=env)
    assert json.loads(p.stdout)["results"][0]["removed"] == [f"eap-route-{H}"] and kube("elsewhere") == []
    p = _cli("teardown", "--hash", H, "--stages", "ingress", "--namespace", "fe-signalloom", "--json")
    assert p.returncode == 0 and kube() == [f"eap-route-{OTHER}"]


# ------------------------------------------------------------------------------
# Ordered 5-stage teardown & path builder tests (SLED P3-GOV)
# ------------------------------------------------------------------------------

def test_ordered_teardown_executes_all_five_stages_in_exact_order(kube, tsmock):
    """Asserts 5 stages execute in order: drain_routes, shred_openbao, revoke_svid, evict_tailscale, delete_namespace."""
    mgr = _draining_manager()
    recorded_stages = []
    report = run_ordered_teardown(
        H,
        manager=mgr,
        recorder=recorded_stages,
    )
    expected_order = [
        TeardownStage.DRAIN_ROUTES,
        TeardownStage.SHRED_OPENBAO,
        TeardownStage.REVOKE_SVID,
        TeardownStage.EVICT_TAILSCALE,
        TeardownStage.DELETE_NAMESPACE,
    ]
    assert recorded_stages == expected_order
    assert report.ok
    assert report.stages_completed == [s.value for s in expected_order]
    assert mgr.get_lifecycle(H).state is EnvironmentLifecycleState.TERMINATED


def test_ordered_teardown_stops_on_stage_k_failure_and_sets_teardown_failed(kube, tsmock, monkeypatch):
    """A failure in stage k stops stages k+1.. and leaves the LifecycleRecord in TEARDOWN_FAILED, never ACTIVE."""
    mgr = _draining_manager()
    monkeypatch.setenv("FAKE_KUBECTL_MODE", "delete-fails")
    recorded_stages = []
    report = run_ordered_teardown(
        H,
        manager=mgr,
        recorder=recorded_stages,
    )
    assert not report.ok
    assert recorded_stages == [TeardownStage.DRAIN_ROUTES]
    rec = mgr.get_lifecycle(H)
    assert rec.state is EnvironmentLifecycleState.TEARDOWN_FAILED
    assert rec.state is not EnvironmentLifecycleState.ACTIVE


def test_resolve_repo_root_path_builder_unit_test():
    """Unit test for resolve_repo_root path builder."""
    root = resolve_repo_root()
    assert (root / "scripts" / "eap" / "tailscale-eap-env.sh").is_file()
    assert (root / "Makefile").is_file()
