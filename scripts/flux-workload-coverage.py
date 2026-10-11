#!/usr/bin/env python3
"""Prove that every workload manifest in this repo is reconciled by a Flux object.

    scripts/flux-workload-coverage.py [--json] [--exceptions FILE] [--list-sets]

WHY THIS EXISTS
---------------
A manifest that exists is not a manifest Flux applies. This repo delivers
through OCI artifacts (`scripts/push-local.sh` -> zot -> OCIRepository), so the
chain from a `Deployment` on disk to a reconciling controller is four hops long:

    workload yaml
      <- kustomization.yaml that lists it as a resource (possibly transitively)
      <- flux Kustomization CR whose spec.path lands on that directory
      <- OCIRepository whose artifact is built from the directory holding it
      <- the fleet overlay (tenants/<overlay>) that the cluster's root
         Kustomization actually points at

Break any hop and the manifest becomes decoration: it is reviewed, committed,
and never applied, while reading exactly like production config. Three live
examples found on 2026-10-11 (`docs/flux-coverage.md`): afm-platform,
inf-signalloom/cardvault and kube-system/sldc-bridge-dns were all running in
kind-osramp with no Flux provenance label at all, applied by `make` targets that
no rebuild would replay.

This gate walks the chain TOP-DOWN from the fleet overlays -- the only direction
that answers the question -- and fails when a workload manifest is reachable
from nothing, unless the exception is declared with a reason in
`docs/flux-coverage-exceptions.yaml`.

It is deliberately static: it needs no cluster, no credentials and no network,
so it runs in CI and offline. A live cross-check is
`kubectl get deploy,sts,ds,cronjob -A -o json` filtered on the
`kustomize.toolkit.fluxcd.io/name` / `helm.toolkit.fluxcd.io/name` /
`resourceset.fluxcd.io/name` labels; see docs/flux-coverage.md.
"""
import argparse
import glob
import json
import os
import re
import sys

import yaml

# flux-operator's ResourceSet templating. `<< inputs.tenant >>` is not YAML, so
# it is tokenised to a bare scalar before parsing. A quoted replacement would
# nest quotes inside already-quoted scalars; a token containing `{` or `.` can
# start a flow mapping. Alphanumerics only.
TPL = re.compile(r'<<\s*(.*?)\s*>>')
TOKEN = re.compile(r'ZZ([A-Za-z0-9_]+)ZZ')
REMOTE = re.compile(r'^https?://|^git::|^github\.com|^ssh://|^oci://')

# OCI artifact repository (the path after the registry, with any `acme/`
# namespace stripped) -> the directory in THIS repo that it is built from.
#
# Derived from the push_* functions in scripts/push-local.sh. Keeping the map
# here rather than parsing the shell is a deliberate trade: a NEW artifact that
# some ResourceSet references but nothing publishes fails this gate with
# `unmapped-artifact` instead of silently resolving to nothing.
ARTIFACT_DIR = {
    'fleet': 'd2-osramp-fleet',
    'signalloom/agent-trust': 'd2-agent-trust/manifests',
    'signalloom/infra/inf-bao': 'd2-signalloom/infra/inf-bao',
    'signalloom/infra/inf-signalloom': 'd2-signalloom/infra/inf-signalloom',
    'signalloom/apps/fe-signalloom': 'd2-signalloom/apps',
    'signalloom/agent-swarm': 'd2-signalloom/infra/agent-swarm',
    'apps/frontend': 'd2-osramp-apps/components/frontend',
    'apps/backend': 'd2-osramp-apps/components/backend',
    'olly/olly-replica': 'olly-replica/components',
    'infra/cert-manager': 'd2-infra/components/cert-manager',
    'infra/ingress': 'd2-infra/components/ingress',
    'infra/monitoring': 'd2-infra/components/monitoring',
    'infra/trivy-system': 'd2-infra/components/trivy-system',
}

# Trees that deliver to a cluster through Flux. Anything outside these is not
# claiming to be GitOps-delivered and is not this gate's business.
DELIVERY_ROOTS = (
    'd2-agent-trust', 'd2-cpai', 'd2-infra', 'd2-k8s-afm', 'd2-osramp-apps',
    'd2-osramp-fleet', 'd2-signalloom', 'olly-replica', 'deploy', 'infra',
)

WORKLOAD_KINDS = {
    'Deployment', 'StatefulSet', 'DaemonSet', 'CronJob', 'Job',
    'ReplicaSet', 'ReplicationController', 'Pod',
}

SKIP_DIRS = {'.git', '.claude', 'node_modules', 'vendor', '.venv', 'testdata'}


def tokenise(match):
    return 'ZZ' + re.sub(r'[^A-Za-z0-9]', '_', match.group(1).strip()) + 'ZZ'


def load_docs(path):
    with open(path, encoding='utf-8', errors='replace') as fh:
        return list(yaml.safe_load_all(TPL.sub(tokenise, fh.read())))


def kustomization_file(directory):
    for name in ('kustomization.yaml', 'kustomization.yml', 'Kustomization'):
        candidate = os.path.join(directory, name)
        if os.path.isfile(candidate):
            return candidate
    return None


class Walker:
    """Traverse a kustomize resource graph, recording files and dangling refs."""

    def __init__(self):
        self.reached = set()
        self.dangling = []

    def walk(self, start, origin, _visited=None):
        visited = _visited if _visited is not None else set()
        directory = os.path.normpath(start)
        if directory in visited:
            return
        visited.add(directory)
        kfile = kustomization_file(directory)
        if kfile is None:
            self.dangling.append((directory + '/kustomization.yaml', origin))
            return
        self.reached.add(kfile)
        try:
            doc = yaml.safe_load(open(kfile, encoding='utf-8')) or {}
        except Exception as exc:  # noqa: BLE001 - reported, not raised
            self.dangling.append((kfile + ' (unparseable: %s)' % exc, origin))
            return
        entries = []
        for key in ('resources', 'bases', 'components', 'patchesStrategicMerge', 'crds'):
            entries += (doc.get(key) or [])
        for patch in (doc.get('patches') or []):
            if isinstance(patch, dict) and patch.get('path'):
                entries.append(patch['path'])
        for gen in (doc.get('configMapGenerator') or []) + (doc.get('secretGenerator') or []):
            for ref in (gen.get('files') or []) + (gen.get('envs') or []):
                entries.append(ref.split('=', 1)[-1])
        for entry in entries:
            if not isinstance(entry, str) or REMOTE.match(entry):
                continue
            target = os.path.normpath(os.path.join(directory, entry))
            if os.path.isdir(target):
                self.walk(target, origin, visited)
            elif os.path.isfile(target):
                self.reached.add(target)
            else:
                self.dangling.append((target, origin))


def cluster_environment(cluster):
    """ENVIRONMENT is set by flux-runtime-info, NOT by the cluster directory name.

    prod-eu and prod-us both resolve to `production`; assuming the directory
    name makes every `./controllers/${ENVIRONMENT}` path read as dangling.
    """
    info = 'd2-osramp-fleet/clusters/%s/flux-system/runtime-info.yaml' % cluster
    if os.path.isfile(info):
        try:
            return (yaml.safe_load(open(info, encoding='utf-8')) or {}) \
                .get('data', {}).get('ENVIRONMENT', cluster)
        except Exception:  # noqa: BLE001
            pass
    return cluster


def resolve_cluster(cluster, walker, problems, roots):
    env = cluster_environment(cluster)

    def subst(value, inputs):
        if not isinstance(value, str):
            return value
        value = TOKEN.sub(
            lambda m: str(inputs.get(m.group(1).split('_')[-1], m.group(0))), value)
        return re.sub(r'\$\{(\w+)\}',
                      lambda m: {'ENVIRONMENT': env}.get(m.group(1), m.group(0)), value)

    # 1. Which fleet manifest files are in play for this cluster? Only the ones
    #    its root Kustomization's overlay actually lists -- tenants/local omits
    #    olly.yaml, so olly must not count as covered on this cluster.
    fleet = Walker()
    for directory in [os.path.dirname(p) for p in
                      glob.glob('d2-osramp-fleet/clusters/%s/**/kustomization.yaml' % cluster,
                                recursive=True)]:
        fleet.walk(directory, 'cluster/' + cluster)
    files = set(fleet.reached) | set(
        glob.glob('d2-osramp-fleet/clusters/%s/**/*.yaml' % cluster, recursive=True))
    overlays = set()
    for path in sorted(files):
        try:
            docs = load_docs(path)
        except Exception as exc:  # noqa: BLE001
            problems.append(('parse-failure', cluster, path, str(exc)))
            continue
        for doc in docs:
            if isinstance(doc, dict) and doc.get('kind') == 'Kustomization' \
                    and str(doc.get('apiVersion', '')).startswith('kustomize.toolkit'):
                spec_path = doc.get('spec', {}).get('path', '')
                if spec_path.startswith('./tenants/'):
                    overlays.add(os.path.normpath(
                        os.path.join('d2-osramp-fleet', spec_path.lstrip('./'))))
    for overlay in sorted(overlays):
        fleet.walk(overlay, 'tenants/' + cluster)
    files |= set(fleet.reached)
    walker.reached |= set(fleet.reached)
    walker.dangling += fleet.dangling

    # 2. Collect the flux objects those files declare.
    ocis, ksts = {}, []
    for path in sorted(f for f in files if f.endswith(('.yaml', '.yml'))):
        try:
            docs = load_docs(path)
        except Exception:  # noqa: BLE001 - already reported above
            continue
        for doc in docs:
            if not isinstance(doc, dict):
                continue
            kind = doc.get('kind')
            if kind == 'ResourceSet':
                for inputs in (doc.get('spec', {}).get('inputs') or [{}]):
                    inputs = dict(inputs)
                    inputs.setdefault('environment', env)
                    for res in (doc.get('spec', {}).get('resources') or []):
                        if not isinstance(res, dict):
                            continue
                        meta = res.get('metadata') or {}
                        if res.get('kind') == 'OCIRepository':
                            ocis[(subst(meta.get('namespace', ''), inputs),
                                  subst(meta.get('name', ''), inputs))] = \
                                subst(res.get('spec', {}).get('url', ''), inputs)
                        elif res.get('kind') == 'Kustomization' and \
                                str(res.get('apiVersion', '')).startswith('kustomize.toolkit'):
                            ksts.append((subst(meta.get('namespace', ''), inputs),
                                         subst(meta.get('name', ''), inputs),
                                         subst(res.get('spec', {}).get('path', ''), inputs),
                                         subst(res.get('spec', {}).get('sourceRef', {})
                                               .get('name', ''), inputs),
                                         subst(res.get('spec', {}).get('sourceRef', {})
                                               .get('kind', ''), inputs),
                                         path))
            elif kind == 'Kustomization' and \
                    str(doc.get('apiVersion', '')).startswith('kustomize.toolkit'):
                meta = doc.get('metadata') or {}
                ref = doc.get('spec', {}).get('sourceRef', {})
                ksts.append((meta.get('namespace', ''), meta.get('name', ''),
                             subst(doc.get('spec', {}).get('path', ''), {}),
                             ref.get('name', ''), ref.get('kind', ''), path))
            elif kind == 'OCIRepository':
                meta = doc.get('metadata') or {}
                ocis[(meta.get('namespace', ''), meta.get('name', ''))] = \
                    doc.get('spec', {}).get('url', '')

    # 3. Resolve each Kustomization CR to a directory in this repo and walk it.
    for ns, name, spec_path, sref, skind, origin_file in ksts:
        who = '%s:%s/%s' % (cluster, ns, name)
        if skind and skind != 'OCIRepository':
            # Image-update automation reads a GitRepository, not an artifact.
            continue
        if 'ZZ' in spec_path:
            problems.append(('unresolved-path', cluster, who, spec_path, origin_file))
            continue
        url = ocis.get((ns, sref))
        if url is None:
            if sref == 'flux-system':
                directories = [ARTIFACT_DIR['fleet']]
            else:
                problems.append(('no-source', cluster, who, sref, origin_file))
                continue
        else:
            match = re.match(r'oci://[^/]+/(.*)$', url)
            repo = match.group(1) if match else url
            repo = re.sub(r'^\$\{REGISTRY_BASE\}/', '', repo)
            repo = re.sub(r'^acme/', '', repo)
            if 'ZZ' in repo:
                # The tenant is injected imperatively (opt-in demos). Every
                # artifact under the prefix is a candidate source.
                prefix = repo.split('ZZ')[0].rstrip('/')
                directories = [v for k, v in ARTIFACT_DIR.items()
                               if k.startswith(prefix + '/')]
                if not directories:
                    problems.append(('no-prefix-match', cluster, who, repo, origin_file))
                    continue
            else:
                directory = ARTIFACT_DIR.get(repo)
                if directory is None:
                    problems.append(('unmapped-artifact', cluster, who, repo, origin_file))
                    continue
                directories = [directory]
        for directory in directories:
            root = os.path.normpath(os.path.join(directory, spec_path.lstrip('./') or '.'))
            roots.setdefault(root, set()).add(who)
            walker.walk(root, who)


def set_a():
    """Every workload manifest the repository declares."""
    rows = []
    for dirpath, dirnames, filenames in os.walk('.'):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for filename in filenames:
            if not filename.endswith(('.yaml', '.yml')):
                continue
            path = os.path.normpath(os.path.join(dirpath, filename))
            if path.startswith('./'):
                path = path[2:]
            if not path.startswith(DELIVERY_ROOTS):
                continue
            try:
                docs = list(yaml.safe_load_all(
                    open(path, encoding='utf-8', errors='replace').read()))
            except Exception:  # noqa: BLE001 - not a manifest we can judge
                continue
            for doc in docs:
                if not isinstance(doc, dict):
                    continue
                kind = doc.get('kind')
                api = str(doc.get('apiVersion', '') or '')
                is_ksvc = kind == 'Service' and api.startswith('serving.knative.dev')
                if kind in WORKLOAD_KINDS or is_ksvc:
                    meta = doc.get('metadata') or {}
                    rows.append({'file': path, 'kind': kind,
                                 'name': meta.get('name', '<unnamed>')})
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--exceptions', default='docs/flux-coverage-exceptions.yaml')
    ap.add_argument('--json', action='store_true')
    ap.add_argument('--list-sets', action='store_true',
                    help='print set A and set B in full, then exit 0')
    args = ap.parse_args()

    repo = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
    os.chdir(repo)

    walker, problems, roots = Walker(), [], {}
    for cluster in sorted(os.path.basename(p)
                          for p in glob.glob('d2-osramp-fleet/clusters/*')
                          if os.path.isdir(p)):
        resolve_cluster(cluster, walker, problems, roots)

    reached = set(os.path.normpath(p) for p in walker.reached)
    rows = set_a()
    covered = [r for r in rows if r['file'] in reached]
    uncovered = [r for r in rows if r['file'] not in reached]

    allowed = {}
    if os.path.isfile(args.exceptions):
        doc = yaml.safe_load(open(args.exceptions, encoding='utf-8')) or {}
        for entry in (doc.get('exceptions') or []):
            allowed[entry['path']] = entry
    stale = sorted(p for p in allowed
                   if p in reached or not os.path.exists(p))
    undeclared = sorted({r['file'] for r in uncovered} - set(allowed))
    dangling = sorted(set(walker.dangling))

    result = {
        'set_a_docs': len(rows),
        'set_b_reached_files': len(reached),
        'covered_docs': len(covered),
        'uncovered_docs': len(uncovered),
        'flux_roots': len(roots),
        'undeclared_uncovered': undeclared,
        'stale_exceptions': stale,
        'dangling_paths': [list(d) for d in dangling],
        'resolution_problems': [list(p) for p in sorted(set(problems))],
    }

    if args.list_sets:
        print('## SET A - workload manifests declared by the repository')
        for r in sorted(rows, key=lambda x: (x['file'], x['kind'], x['name'])):
            mark = 'FLUX' if r['file'] in reached else '----'
            print('  %s  %-74s %-12s %s' % (mark, r['file'], r['kind'], r['name']))
        print('\n## SET B - directories a Flux object reconciles')
        for root in sorted(roots):
            print('  %-66s %s' % (root, ','.join(sorted(roots[root]))))
        return 0

    if args.json:
        json.dump(result, sys.stdout, indent=2)
        print()
    else:
        print('set A (workload docs declared): %d' % result['set_a_docs'])
        print('set B (flux roots / reached files): %d / %d'
              % (result['flux_roots'], result['set_b_reached_files']))
        print('covered: %d   uncovered: %d (declared exceptions: %d)'
              % (len(covered), len(uncovered), len(allowed)))
        for label, items in (('UNDECLARED UNCOVERED WORKLOAD', undeclared),
                             ('STALE EXCEPTION', stale)):
            for item in items:
                print('%s: %s' % (label, item))
        for path, origin in dangling:
            print('DANGLING FLUX PATH: %s (from %s)' % (path, origin))
        for problem in sorted(set(problems)):
            print('RESOLUTION PROBLEM: %s' % (problem,))

    bad = undeclared or stale or dangling or problems
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
