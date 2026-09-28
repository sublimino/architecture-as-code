import json
import os
import stat
import time
from pathlib import Path

import pytest

from environment_teardown_adapters import (
    ConfiguredTeardownExecutor,
    FailClosedExecutor,
    KeySpireAdapter,
    KubernetesNamespaceStorageClient,
    MeshAdapter,
    NamespaceStorageAdapter,
    RouteAdapter,
    TailscaleAdminAPIClient,
    build_teardown_executor,
    run_bounded,
)
from environment_teardown_contract import (
    StageRequest,
    StageResult,
    TeardownAuthorizationError,
    TeardownStage,
)


def request(customer_hash="0123abcd", seconds=2.0):
    return StageRequest(customer_hash, "teardown-1", time.monotonic() + seconds)


class RecordingAdapter:
    def __init__(self, result):
        self.result = result
        self.calls = []

    def execute(self, stage_request):
        self.calls.append(stage_request)
        return self.result

    def verify(self, stage_request):
        self.calls.append(stage_request)
        return self.result


def test_fail_closed_executor_never_succeeds():
    result = FailClosedExecutor("provider absent").execute(TeardownStage.ROUTE, request())
    assert not result.success
    assert result.stage is TeardownStage.ROUTE
    assert result.evidence == {"configured": False}


def test_default_factory_is_fail_closed(monkeypatch):
    for name in list(os.environ):
        if name.startswith("SIGNALLOOM_TEARDOWN_"):
            monkeypatch.delenv(name, raising=False)
    executor = build_teardown_executor()
    for stage in TeardownStage:
        assert not executor.execute(stage, request()).success


def test_factory_rejects_incomplete_explicit_provider_configuration(monkeypatch):
    monkeypatch.setenv("SIGNALLOOM_TEARDOWN_ROUTE_PROVIDER", "kubectl")
    monkeypatch.delenv("SIGNALLOOM_TEARDOWN_KUBECTL", raising=False)
    monkeypatch.delenv("SIGNALLOOM_TEARDOWN_ROUTE_NAMESPACE", raising=False)
    with pytest.raises(ValueError, match="missing explicit teardown configuration"):
        build_teardown_executor()


def test_invalid_hash_is_rejected_before_provider_call():
    adapter = RecordingAdapter(StageResult(TeardownStage.ROUTE, True))
    executor = ConfiguredTeardownExecutor({TeardownStage.ROUTE: adapter})
    result = executor.execute(TeardownStage.ROUTE, request("NOT-HASH"))
    assert not result.success and "customer_hash" in result.detail
    assert adapter.calls == []


def test_unknown_stage_never_returns_success():
    executor = ConfiguredTeardownExecutor({})
    result = executor.execute("route", request())
    assert not result.success and "unknown teardown stage" in result.detail


def test_dispatch_rejects_provider_result_for_another_stage():
    adapter = RecordingAdapter(StageResult(TeardownStage.MESH, True))
    result = ConfiguredTeardownExecutor({TeardownStage.ROUTE: adapter}).execute(
        TeardownStage.ROUTE, request()
    )
    assert not result.success and "mismatched stage" in result.detail


def test_expired_deadline_prevents_provider_invocation():
    adapter = RecordingAdapter(StageResult(TeardownStage.ROUTE, True))
    result = ConfiguredTeardownExecutor({TeardownStage.ROUTE: adapter}).execute(
        TeardownStage.ROUTE, request(seconds=-1)
    )
    assert not result.success and "deadline" in result.detail
    assert adapter.calls == []


def test_run_bounded_kills_process_group_on_deadline(tmp_path):
    marker = tmp_path / "finished"
    result = run_bounded(
        ["bash", "-c", f"sleep 5; touch {marker}"], time.monotonic() + 0.15
    )
    assert result.returncode is None and result.timed_out
    time.sleep(0.1)
    assert not marker.exists()


def _fake_kubectl(tmp_path: Path) -> tuple[Path, Path]:
    state = tmp_path / "state.json"
    state.write_text(json.dumps({"routes": ["tenant", "other"], "namespace": True, "pv": False}))
    binary = tmp_path / "kubectl"
    binary.write_text(
        """#!/usr/bin/env python3
import json, os, sys
p=os.environ['FAKE_STATE']; s=json.load(open(p)); a=sys.argv[1:]
if a[:2] == ['get','httproute']:
 print(json.dumps({'items':[{'metadata':{'name':'tenant','labels':{'signalloom.io/eap-hash':'0123abcd'}},'spec':{}}, {'metadata':{'name':'other','labels':{'signalloom.io/eap-hash':'deadbeef'}},'spec':{}}] if 'tenant' in s['routes'] else [{'metadata':{'name':'other','labels':{'signalloom.io/eap-hash':'deadbeef'}},'spec':{}}]})); sys.exit(0)
if a[:2] == ['delete','httproute']:
 s['routes'].remove(a[2]); json.dump(s,open(p,'w')); sys.exit(0)
if a[:2] == ['get','namespace']:
 sys.exit(0 if s['namespace'] else 1)
if a[:2] == ['get','pvc']:
 print(json.dumps({'items':[]})); sys.exit(0)
if a[:2] == ['get','pv']:
 print(json.dumps({'items':[]})); sys.exit(0)
if a[:2] == ['delete','namespace']:
 s['namespace']=False; json.dump(s,open(p,'w')); sys.exit(0)
sys.exit(2)
"""
    )
    binary.chmod(binary.stat().st_mode | stat.S_IXUSR)
    return binary, state


def test_route_adapter_deletes_only_matching_routes_and_relists(tmp_path, monkeypatch):
    kubectl, state = _fake_kubectl(tmp_path)
    monkeypatch.setenv("FAKE_STATE", str(state))
    result = RouteAdapter(str(kubectl), "fe-signalloom").execute(request())
    assert result.success
    assert result.evidence["removed_routes"] == ["tenant"]
    assert result.evidence["remaining_routes"] == []
    assert json.loads(state.read_text())["routes"] == ["other"]


class FakeMesh:
    def __init__(self, nodes):
        self.nodes = list(nodes)
        self.deleted = []

    def list_nodes(self, timeout):
        return list(self.nodes)

    def delete_node(self, node_id, timeout):
        self.deleted.append(node_id)
        self.nodes = [node for node in self.nodes if node["id"] != node_id]


class TimeoutRecordingMesh(FakeMesh):
    def __init__(self):
        super().__init__([])
        self.timeouts = []

    def list_nodes(self, timeout):
        self.timeouts.append(timeout)
        return super().list_nodes(timeout)


def test_mesh_adapter_deletes_only_exact_tenant_nodes_and_verifies_absence():
    client = FakeMesh([
        {"id": "one", "hostname": "sl-eap-0123abcd", "tags": ["tag:eap-0123abcd"]},
        {"id": "two", "hostname": "sl-eap-deadbeef", "tags": ["tag:eap-deadbeef"]},
    ])
    ownership = {"0123abcd": {"device_ids": ["one"], "tag": "tag:eap-0123abcd"}}
    result = MeshAdapter(client, ownership=ownership).execute(request())
    assert result.success and client.deleted == ["one"]
    assert result.evidence["remaining_tenant_nodes"] == []
    assert client.nodes == [{"id": "two", "hostname": "sl-eap-deadbeef", "tags": ["tag:eap-deadbeef"]}]


def test_mesh_adapter_fails_when_api_still_lists_tenant_node():
    client = FakeMesh([{"id": "one", "hostname": "sl-eap-0123abcd", "tags": ["tag:eap-0123abcd"]}])
    client.delete_node = lambda node_id, timeout: None
    ownership = {"0123abcd": {"device_ids": ["one"], "tag": "tag:eap-0123abcd"}}
    result = MeshAdapter(client, ownership=ownership).execute(request())
    assert not result.success and result.evidence["remaining_tenant_nodes"] == ["one"]


def test_injected_provider_calls_are_capped_at_ten_seconds():
    client = TimeoutRecordingMesh()
    ownership = {"0123abcd": {"device_ids": [], "tag": "tag:eap-0123abcd"}}
    result = MeshAdapter(client, ownership=ownership).execute(request(seconds=60))
    assert result.success
    assert client.timeouts and all(0 < timeout <= 10 for timeout in client.timeouts)


class FakeBao:
    def __init__(self, *, survives=False, decrypt_fails=True):
        self.survives = survives
        self.decrypt_failure = decrypt_fails

    def delete_tenant_material(self, customer_hash, timeout):
        return None

    def key_exists(self, customer_hash, timeout):
        return self.survives

    def secret_exists(self, customer_hash, timeout):
        return self.survives

    def decrypt_fails(self, customer_hash, timeout):
        return self.decrypt_failure


class FakeSpire:
    def __init__(self, entries):
        self.entries = list(entries)

    def list_entries(self, timeout):
        return list(self.entries)

    def delete_entry(self, entry_id, timeout):
        self.entries = [entry for entry in self.entries if entry["id"] != entry_id]


def test_key_spire_adapter_requires_verified_key_decrypt_and_entry_absence():
    spire = FakeSpire([
        {"id": "tenant", "spiffe_id": "spiffe://signalloom.demo/ns/eap-0123abcd/sa/app"},
        {"id": "other", "spiffe_id": "spiffe://signalloom.demo/ns/eap-deadbeef/sa/app"},
    ])
    result = KeySpireAdapter(FakeBao(), spire).execute(request())
    assert result.success
    assert result.evidence["openbao"] == {
        "key_absent": True,
        "secret_absent": True,
        "decrypt_failed": True,
        "backup_erasure": "unverified",
    }
    assert result.evidence["spire_remaining_entries"] == []
    assert spire.entries[0]["id"] == "other"


@pytest.mark.parametrize("bao", [FakeBao(survives=True), FakeBao(decrypt_fails=False)])
def test_key_spire_adapter_fails_without_crypto_postconditions(bao):
    result = KeySpireAdapter(bao, FakeSpire([])).execute(request())
    assert not result.success


class FakeNamespaceStorage:
    def __init__(self, *, namespace_absent=True, storage_verified=True):
        self.namespace_absent = namespace_absent
        self.storage_verified = storage_verified

    def delete_namespace(self, namespace, timeout):
        return None

    def namespace_exists(self, namespace, timeout):
        return not self.namespace_absent

    def storage_absence_proof(self, namespace, timeout):
        return {"verified": self.storage_verified, "retained_resources": []}


def test_namespace_storage_requires_both_verified_postconditions():
    result = NamespaceStorageAdapter(FakeNamespaceStorage()).execute(request())
    assert result.success
    assert result.evidence["namespace_absent"] is True
    assert result.evidence["storage"]["verified"] is True


@pytest.mark.parametrize(
    "provider", [
        FakeNamespaceStorage(namespace_absent=False),
        FakeNamespaceStorage(storage_verified=False),
    ],
)
def test_namespace_storage_fails_if_either_postcondition_is_unproved(provider):
    assert not NamespaceStorageAdapter(provider).execute(request()).success


def test_kubernetes_namespace_storage_403_forbidden_fails_closed(tmp_path):
    path = tmp_path / "kubectl"
    path.write_text("#!/usr/bin/env python3\nimport sys; print('Error from server (Forbidden): namespaces eap-0123abcd is forbidden', file=sys.stderr); sys.exit(1)\n")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)

    client = KubernetesNamespaceStorageClient(str(path), "kubernetes-pv")
    with pytest.raises(TeardownAuthorizationError, match="namespace_lookup_failed"):
        client.namespace_exists("eap-0123abcd", 1)


def test_kubernetes_namespace_deletion_403_forbidden_fails_closed(tmp_path):
    path = tmp_path / "kubectl"
    path.write_text("#!/usr/bin/env python3\nimport sys; print('Error from server (Forbidden): namespaces eap-0123abcd is forbidden', file=sys.stderr); sys.exit(1)\n")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)

    client = KubernetesNamespaceStorageClient(str(path), "kubernetes-pv")
    with pytest.raises(TeardownAuthorizationError, match="namespace_lookup_failed"):
        client.delete_namespace("eap-0123abcd", 1)


def test_tailscale_403_forbidden_fails_closed(monkeypatch):
    client = TailscaleAdminAPIClient("https://api.tailscale.com", "example", "secret")
    monkeypatch.setattr(client.transport, "request", lambda *args, **kwargs: (403, {}, b'{"message":"forbidden"}'))
    with pytest.raises(TeardownAuthorizationError):
        client.list_nodes(1)
