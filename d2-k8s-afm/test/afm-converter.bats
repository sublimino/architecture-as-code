#!/usr/bin/env bats
# Static validation of the AFM converter contract and RBAC manifests.
# No cluster required — runs offline against fixtures.

setup() {
  repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  fixtures="$repo_root/d2-k8s-afm/test/fixtures"
  converter="$repo_root/scripts/rbac-to-afm.py"
  manifest="$repo_root/d2-k8s-afm/apps/afm-platform/base/cluster-import.yaml"
}

# -- Converter shape validation ------------------------------------------------

@test "converter produces valid JSON with required top-level keys" {
  run python3 -c "
import json, importlib.util, sys
spec = importlib.util.spec_from_file_location('c', '$converter')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = m.convert(json.load(open('$fixtures/osramp-cluster-rbac.json')))
assert sorted(d.keys()) == ['id', 'name', 'rbac'], f'bad top keys: {sorted(d.keys())}'
assert sorted(d['rbac'].keys()) == ['bindings', 'roles', 'subjects'], f'bad rbac keys: {sorted(d[\"rbac\"].keys())}'
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "every converted role has name, scope, and rules" {
  run python3 -c "
import json, importlib.util
spec = importlib.util.spec_from_file_location('c', '$converter')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = m.convert(json.load(open('$fixtures/osramp-cluster-rbac.json')))
for i, r in enumerate(d['rbac']['roles']):
    assert 'name' in r, f'role {i} missing name'
    assert 'scope' in r, f'role {i} missing scope'
    assert 'rules' in r and isinstance(r['rules'], list), f'role {i} missing rules list'
    if r['scope'] == 'Namespace':
        assert 'namespace' in r, f'namespace-scoped role {r[\"name\"]} missing namespace field'
print(f'OK: {len(d[\"rbac\"][\"roles\"])} roles validated')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "every converted binding has name, scope, roleRef, and subjects" {
  run python3 -c "
import json, importlib.util
spec = importlib.util.spec_from_file_location('c', '$converter')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = m.convert(json.load(open('$fixtures/osramp-cluster-rbac.json')))
for i, b in enumerate(d['rbac']['bindings']):
    assert 'name' in b, f'binding {i} missing name'
    assert 'scope' in b, f'binding {i} missing scope'
    assert 'roleRef' in b and isinstance(b['roleRef'], str), f'binding {i} missing/bad roleRef'
    assert 'subjects' in b and isinstance(b['subjects'], list), f'binding {i} missing subjects list'
    if b['scope'] == 'Namespace':
        assert 'namespace' in b, f'namespace-scoped binding {b[\"name\"]} missing namespace field'
print(f'OK: {len(d[\"rbac\"][\"bindings\"])} bindings validated')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "every converted subject has name and kind" {
  run python3 -c "
import json, importlib.util
spec = importlib.util.spec_from_file_location('c', '$converter')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = m.convert(json.load(open('$fixtures/osramp-cluster-rbac.json')))
for i, s in enumerate(d['rbac']['subjects']):
    assert 'name' in s and s['name'], f'subject {i} missing name'
    assert 'kind' in s and s['kind'], f'subject {i} missing kind'
    if s['kind'] == 'ServiceAccount':
        assert 'namespace' in s, f'SA subject {s[\"name\"]} missing namespace'
print(f'OK: {len(d[\"rbac\"][\"subjects\"])} subjects validated')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "converter produces non-trivial output from the raw fixture" {
  run python3 -c "
import json, importlib.util
spec = importlib.util.spec_from_file_location('c', '$converter')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = m.convert(json.load(open('$fixtures/osramp-cluster-rbac.json')))
assert len(d['rbac']['subjects']) > 10, f'too few subjects: {len(d[\"rbac\"][\"subjects\"])}'
assert len(d['rbac']['roles']) > 10, f'too few roles: {len(d[\"rbac\"][\"roles\"])}'
assert len(d['rbac']['bindings']) > 10, f'too few bindings: {len(d[\"rbac\"][\"bindings\"])}'
print(f'OK: {len(d[\"rbac\"][\"subjects\"])}s {len(d[\"rbac\"][\"roles\"])}r {len(d[\"rbac\"][\"bindings\"])}b')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "converter deduplicates subjects across multiple bindings" {
  run python3 -c "
import json, importlib.util
spec = importlib.util.spec_from_file_location('c', '$converter')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = m.convert(json.load(open('$fixtures/osramp-cluster-rbac.json')))
seen = set()
for s in d['rbac']['subjects']:
    key = f'{s[\"kind\"]}/{s.get(\"namespace\",\"\")}/{s[\"name\"]}'
    assert key not in seen, f'duplicate subject: {key}'
    seen.add(key)
print(f'OK: {len(seen)} unique subjects, no duplicates')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "converter handles raw list, single resource dict, and None inputs without error" {
  run python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('c', '$converter')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

# 1. Raw list of items
d1 = m.convert([{'kind': 'Role', 'metadata': {'name': 'r1', 'namespace': 'default'}, 'rules': [{'verbs': ['get'], 'resources': ['pods']}]}])
assert len(d1['rbac']['roles']) == 1
assert d1['rbac']['roles'][0]['name'] == 'r1'

# 2. Single object dict
d2 = m.convert({'kind': 'ClusterRole', 'metadata': {'name': 'cr1'}, 'rules': []})
assert len(d2['rbac']['roles']) == 1
assert d2['rbac']['roles'][0]['name'] == 'cr1'

# 3. None input
d3 = m.convert(None)
assert d3['rbac']['roles'] == []
assert d3['rbac']['subjects'] == []
assert d3['rbac']['bindings'] == []
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# -- AFM fixture shape validation ----------------------------------------------

@test "AFM fixture has the same contract shape as converter output" {
  run python3 -c "
import json
d = json.load(open('$fixtures/osramp-cluster-afm.json'))
assert sorted(d.keys()) == ['id', 'name', 'rbac']
assert sorted(d['rbac'].keys()) == ['bindings', 'roles', 'subjects']
assert d['id'] == 'local'
assert d['name'] == 'Local Cluster'
assert len(d['rbac']['subjects']) > 0
assert len(d['rbac']['roles']) > 0
assert len(d['rbac']['bindings']) > 0
print(f'OK: {len(d[\"rbac\"][\"subjects\"])}s {len(d[\"rbac\"][\"roles\"])}r {len(d[\"rbac\"][\"bindings\"])}b')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "AFM fixture contains fe-signalloom namespace roles" {
  run python3 -c "
import json
d = json.load(open('$fixtures/osramp-cluster-afm.json'))
ns_roles = [r for r in d['rbac']['roles'] if r.get('namespace') == 'fe-signalloom']
assert len(ns_roles) >= 2, f'expected >=2 fe-signalloom roles, got {len(ns_roles)}'
names = [r['name'] for r in ns_roles]
assert 'fe-signalloom-health-reader' in names, f'missing health-reader in {names}'
print(f'OK: {len(ns_roles)} fe-signalloom roles: {names}')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# -- RBAC manifest validation --------------------------------------------------

@test "afm-rbac-reader grants get and list on all four RBAC resource types" {
  for resource in clusterroles clusterrolebindings roles rolebindings; do
    run yq eval-all '
      select(.kind == "ClusterRole" and .metadata.name == "afm-rbac-reader")
      | .rules[] | select(.resources[] == "'"$resource"'")
      | .verbs[]' "$manifest"
    [[ "$output" == *"get"* ]]
    [[ "$output" == *"list"* ]]
  done
}

@test "afm-rbac-reader grants get and list on namespaces and serviceaccounts" {
  for resource in namespaces serviceaccounts; do
    run yq eval-all '
      select(.kind == "ClusterRole" and .metadata.name == "afm-rbac-reader")
      | .rules[] | select(.resources[] == "'"$resource"'")
      | .verbs[]' "$manifest"
    [[ "$output" == *"get"* ]]
    [[ "$output" == *"list"* ]]
  done
}

@test "afm-rbac-reader does not grant write verbs" {
  run yq eval-all '
    select(.kind == "ClusterRole" and .metadata.name == "afm-rbac-reader")
    | [.rules[].verbs[]] | unique | .[]' "$manifest"
  [[ "$output" != *"create"* ]]
  [[ "$output" != *"delete"* ]]
  [[ "$output" != *"patch"* ]]
  [[ "$output" != *"update"* ]]
  [[ "$output" != *"*"* ]]
}

# -- Kustomize build sanity ----------------------------------------------------

@test "kustomize build includes the cluster-import CronJob" {
  run kubectl kustomize "$repo_root/d2-k8s-afm/apps/afm-platform/local"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind: CronJob"* ]]
  [[ "$output" == *"afm-cluster-import"* ]]
}
