#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
"""Read-only RBAC exporter for Signal Loom.

Collects ClusterRoles, ClusterRoleBindings, Roles, RoleBindings, Namespaces,
and ServiceAccounts from the local Kubernetes API, converts them to the AFM
import contract, and pushes them to fe-signalloom's authenticated AFM import
gateway route.

Exit codes:
  0: Success (imported)
  2: Configuration error (e.g. missing AFM_CLUSTER_ID, invalid API base URL)
  3: Key error (missing, short < 32 bytes, or whitespace key)
  4: Collection error (failed to list Kubernetes API resources, fail-closed)
  5: Import error (AFM refused with non-2xx status or connection failed)
"""

import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT = 30

RESOURCES = (
    ('clusterroles', 'ClusterRole', '/apis/rbac.authorization.k8s.io/v1/clusterroles'),
    ('clusterrolebindings', 'ClusterRoleBinding', '/apis/rbac.authorization.k8s.io/v1/clusterrolebindings'),
    ('roles', 'Role', '/apis/rbac.authorization.k8s.io/v1/roles'),
    ('rolebindings', 'RoleBinding', '/apis/rbac.authorization.k8s.io/v1/rolebindings'),
    ('namespaces', 'Namespace', '/api/v1/namespaces'),
    ('serviceaccounts', 'ServiceAccount', '/api/v1/serviceaccounts'),
)


def validate_config():
    cluster_id = os.environ.get('AFM_CLUSTER_ID')
    if not cluster_id:
        print('ERROR: AFM_CLUSTER_ID environment variable is required', file=sys.stderr)
        sys.exit(2)

    cluster_name = os.environ.get('AFM_CLUSTER_NAME') or cluster_id

    api_base = os.environ.get('RBAC_EXPORTER_API_BASE')
    if not api_base:
        k8s_host = os.environ.get('KUBERNETES_SERVICE_HOST')
        k8s_port = os.environ.get('KUBERNETES_SERVICE_PORT')
        if k8s_host and k8s_port:
            api_base = f'https://{k8s_host}:{k8s_port}'
        else:
            api_base = 'https://kubernetes.default.svc'

    # Security check: http:// is strictly forbidden unless connecting to 127.0.0.1
    if api_base.startswith('http://'):
        parsed = urllib.parse.urlparse(api_base)
        hostname = parsed.hostname
        if hostname != '127.0.0.1':
            print(f'ERROR: Insecure http:// API base {api_base!r} is only permitted for 127.0.0.1', file=sys.stderr)
            sys.exit(2)

    token_file = os.environ.get('RBAC_EXPORTER_TOKEN_FILE', '/var/run/secrets/kubernetes.io/serviceaccount/token')
    ca_file = os.environ.get('RBAC_EXPORTER_CA_FILE', '/var/run/secrets/kubernetes.io/serviceaccount/ca.crt')
    key_file = os.environ.get('RBAC_EXPORTER_KEY_FILE', '/etc/signalloom-rbac-exporter/afm-key/token')
    import_url = os.environ.get(
        'AFM_IMPORT_URL',
        'http://fe-signalloom-api.fe-signalloom.svc.cluster.local:8000/api/v1/afm/clusters/import'
    )

    return {
        'cluster_id': cluster_id,
        'cluster_name': cluster_name,
        'api_base': api_base.rstrip('/'),
        'token_file': token_file,
        'ca_file': ca_file,
        'key_file': key_file,
        'import_url': import_url,
    }


def load_afm_key(key_file):
    if not os.path.exists(key_file):
        print(f'ERROR: AFM key file {key_file!r} does not exist', file=sys.stderr)
        sys.exit(3)

    try:
        with open(key_file, 'r', encoding='utf-8') as f:
            key = f.read().strip()
    except Exception as exc:
        print(f'ERROR: Failed to read AFM key file {key_file!r}: {exc}', file=sys.stderr)
        sys.exit(3)

    if not key or len(key) < 32:
        print(
            f'ERROR: AFM key in {key_file!r} is invalid (must be at least 32 non-whitespace characters)',
            file=sys.stderr
        )
        sys.exit(3)

    return key


def get_k8s_auth_and_context(token_file, ca_file, api_base):
    if api_base.startswith('https://'):
        if os.path.exists(ca_file):
            ctx = ssl.create_default_context(cafile=ca_file)
        else:
            ctx = ssl.create_default_context()
    else:
        ctx = None

    token = None
    if os.path.exists(token_file):
        try:
            with open(token_file, 'r', encoding='utf-8') as f:
                token = f.read().strip()
        except Exception as exc:
            print(f'ERROR: Failed to read SA token {token_file!r}: {exc}', file=sys.stderr)
            sys.exit(4)

    headers = {}
    if token:
        headers['Authorization'] = f'Bearer {token}'

    return headers, ctx


def collect_resources(api_base, headers, ctx):
    items = []
    for resource, kind, path in RESOURCES:
        url = f'{api_base}{path}?limit=500'
        while url:
            req = urllib.request.Request(url, headers=headers)
            try:
                with urllib.request.urlopen(req, context=ctx, timeout=TIMEOUT) as resp:
                    data = json.load(resp)
            except urllib.error.HTTPError as exc:
                print(f'ERROR: Kubernetes API {resource} request failed: HTTP {exc.code} {exc.reason}', file=sys.stderr)
                sys.exit(4)
            except Exception as exc:
                print(f'ERROR: Failed to list Kubernetes API {resource}: {exc}', file=sys.stderr)
                sys.exit(4)

            for item in data.get('items') or []:
                item['kind'] = kind
                items.append(item)

            cont = data.get('metadata', {}).get('continue')
            if cont:
                sep = '&' if '?' in path else '?'
                url = f'{api_base}{path}{sep}limit=500&continue={urllib.parse.quote(cont)}'
            else:
                url = None

    return items


def convert_rbac(items, cluster_id, cluster_name):
    subjects_seen = {}
    roles = []
    bindings = []

    for item in items:
        kind = item.get('kind', '')
        meta = item.get('metadata') or {}
        name = meta.get('name', '')
        namespace = meta.get('namespace', '')

        if kind == 'ServiceAccount':
            key = f'ServiceAccount/{namespace}/{name}' if namespace else f'ServiceAccount/{name}'
            if key not in subjects_seen:
                seen = {'name': name, 'kind': 'ServiceAccount'}
                if namespace:
                    seen['namespace'] = namespace
                subjects_seen[key] = seen

        elif kind in ('ClusterRole', 'Role'):
            scope = 'Cluster' if kind == 'ClusterRole' else 'Namespace'
            rules = [
                {
                    'verbs': rule.get('verbs') or [],
                    'apiGroups': rule.get('apiGroups') or [''],
                    'resources': rule.get('resources') or [],
                }
                for rule in (item.get('rules') or [])
            ]
            role = {'name': name, 'scope': scope, 'rules': rules}
            if scope == 'Namespace' and namespace:
                role['namespace'] = namespace
            roles.append(role)

        elif kind in ('ClusterRoleBinding', 'RoleBinding'):
            scope = 'Cluster' if kind == 'ClusterRoleBinding' else 'Namespace'
            role_ref = item.get('roleRef') or {}
            binding_subjects = []
            for subject in (item.get('subjects') or []):
                s_kind = subject.get('kind', 'User')
                s_name = subject.get('name', '')
                s_ns = subject.get('namespace', '')
                key = f'{s_kind}/{s_ns}/{s_name}' if s_ns else f'{s_kind}/{s_name}'
                if key not in subjects_seen:
                    seen = {'name': s_name, 'kind': s_kind}
                    if s_kind == 'ServiceAccount' and s_ns:
                        seen['namespace'] = s_ns
                    subjects_seen[key] = seen
                entry = {'kind': s_kind, 'name': s_name}
                if s_ns:
                    entry['namespace'] = s_ns
                binding_subjects.append(entry)

            binding = {
                'name': name,
                'scope': scope,
                'roleRef': role_ref.get('name', ''),
                'subjects': binding_subjects,
            }
            if scope == 'Namespace' and namespace:
                binding['namespace'] = namespace
            bindings.append(binding)

    return {
        'id': cluster_id,
        'name': cluster_name,
        'rbac': {
            'subjects': list(subjects_seen.values()),
            'roles': roles,
            'bindings': bindings,
        },
    }


def push_to_afm(import_url, payload, key, key_name):
    req_data = json.dumps(payload).encode('utf-8')
    headers = {
        'Content-Type': 'application/json',
        'Authorization': f'Bearer {key}',
    }
    req = urllib.request.Request(import_url, data=req_data, headers=headers, method='POST')

    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            status = resp.status
            if 200 <= status < 300:
                print(f'Successfully imported cluster {payload["id"]!r} to AFM (key {key_name!r}): HTTP {status}')
                return
            print(f'ERROR: AFM returned non-2xx status HTTP {status} for key {key_name!r}', file=sys.stderr)
            sys.exit(5)
    except urllib.error.HTTPError as exc:
        print(f'ERROR: AFM import refused HTTP {exc.code} for key {key_name!r}: {exc.reason}', file=sys.stderr)
        sys.exit(5)
    except Exception as exc:
        print(f'ERROR: AFM import connection failed for key {key_name!r}: {exc}', file=sys.stderr)
        sys.exit(5)


def main():
    config = validate_config()
    key_name = os.path.basename(config['key_file'])
    key = load_afm_key(config['key_file'])

    k8s_headers, ssl_ctx = get_k8s_auth_and_context(
        config['token_file'], config['ca_file'], config['api_base']
    )

    items = collect_resources(config['api_base'], k8s_headers, ssl_ctx)
    payload = convert_rbac(items, config['cluster_id'], config['cluster_name'])

    push_to_afm(config['import_url'], payload, key, key_name)
    sys.exit(0)


if __name__ == '__main__':
    main()
