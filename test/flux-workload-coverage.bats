#!/usr/bin/env bats
#
# Gate: every workload manifest in a delivery root must be reconciled by a Flux
# object, or be declared in docs/flux-coverage-exceptions.yaml with a reason.
#
# @id     flux-workload-coverage
# @target scripts/flux-workload-coverage.py
# @doc    docs/flux-coverage.md
#
# The defect class this pins: a manifest that exists is not a manifest Flux
# applies. Delivery here is OCI-artifact based (push-local.sh -> zot ->
# OCIRepository), so the chain from a Deployment on disk to a reconciling
# controller is four hops; break any one and the manifest becomes decoration
# that reads exactly like production config. Measured on 2026-10-11 against the
# live kind-osramp estate: ~30 workloads across 6 namespaces were running with
# no Flux provenance label at all, and 34 of 115 kustomization.yaml files in the
# tree were reachable from no Flux object.
#
# MUTATION DISCIPLINE. Every mutation below is restored from an explicit `cp`
# backup this file created, and never from `git checkout -- .`. That is not
# style: a mutation applied to an UNTRACKED file is not undone by the index, and
# an unstaged fix to a TRACKED file IS -- same command, opposite effects, and
# both have already cost this build real work. Test 2 creates untracked files
# (restored with `rm -rf`), tests 3-6 mutate a tracked file (restored with `cp`).
#
# No mutation touches a file Flux reconciles into the live estate. The
# ${ENVIRONMENT} invariant (test 7) is asserted by calling the resolver
# directly rather than by editing a runtime-info ConfigMap, precisely so this
# suite cannot publish a mutated fleet if it races a push.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
	GATE="${REPO_ROOT}/scripts/flux-workload-coverage.py"
	EXC="${REPO_ROOT}/docs/flux-coverage-exceptions.yaml"
	EXC_BACKUP="${BATS_TEST_TMPDIR}/exceptions.backup.yaml"
	MUTANT_DIR="${REPO_ROOT}/d2-signalloom/apps/zz-coverage-mutation-probe"
	cp "$EXC" "$EXC_BACKUP"
}

teardown() {
	# Restore from OUR backup, in this order: the tracked file first (so a
	# failure in the untracked cleanup still leaves the register correct).
	if [ -f "$EXC_BACKUP" ]; then
		cp "$EXC_BACKUP" "$EXC"
	fi
	rm -rf "$MUTANT_DIR"
}

@test "1. the committed tree passes: every unmanaged workload is declared" {
	run python3 "$GATE"
	[ "$status" -eq 0 ]
	[[ "$output" != *"UNDECLARED"* ]]
	[[ "$output" != *"STALE"* ]]
	[[ "$output" != *"DANGLING"* ]]
	[[ "$output" != *"MALFORMED"* ]]
}

@test "2. MUTATION a new workload manifest with no Flux object naming it FAILS" {
	mkdir -p "$MUTANT_DIR/base"
	cat >"$MUTANT_DIR/base/deployment.yaml" <<-'YAML'
		apiVersion: apps/v1
		kind: Deployment
		metadata:
		  name: zz-coverage-mutation-probe
		spec:
		  replicas: 1
		  selector:
		    matchLabels: {app: zz-coverage-mutation-probe}
		  template:
		    metadata:
		      labels: {app: zz-coverage-mutation-probe}
		    spec:
		      containers:
		        - name: probe
		          image: busybox:1.36
	YAML
	# A kustomization.yaml beside it, so this is not merely a stray file: it is
	# a plausible, well-formed slice that simply no Kustomization CR points at.
	cat >"$MUTANT_DIR/base/kustomization.yaml" <<-'YAML'
		apiVersion: kustomize.config.k8s.io/v1beta1
		kind: Kustomization
		resources:
		  - deployment.yaml
	YAML

	run python3 "$GATE"
	[ "$status" -ne 0 ]
	[[ "$output" == *"UNDECLARED UNMANAGED WORKLOAD"* ]]
	[[ "$output" == *"zz-coverage-mutation-probe"* ]]

	rm -rf "$MUTANT_DIR"
	run python3 "$GATE"
	[ "$status" -eq 0 ]
}

@test "3. MUTATION removing a declared exception for a gap that still exists FAILS" {
	# The other direction, and the one that stops the register being a waiver:
	# deleting an entry must not make the gap disappear, it must re-expose it.
	local victim="d2-k8s-afm/apps/afm-platform/base/deployment.yaml"
	grep -q "$victim" "$EXC"

	python3 - "$EXC" "$victim" <<-'PY'
		import sys, yaml
		path, victim = sys.argv[1], sys.argv[2]
		doc = yaml.safe_load(open(path))
		doc['exceptions'] = [e for e in doc['exceptions'] if e['path'] != victim]
		yaml.safe_dump(doc, open(path, 'w'))
	PY

	run python3 "$GATE"
	[ "$status" -ne 0 ]
	[[ "$output" == *"UNDECLARED UNMANAGED WORKLOAD: ${victim}"* ]]
}

@test "4. MUTATION an exception for a path that no longer exists FAILS as stale" {
	python3 - "$EXC" <<-'PY'
		import sys, yaml
		path = sys.argv[1]
		doc = yaml.safe_load(open(path))
		doc['exceptions'].append({
		    'path': 'd2-signalloom/apps/zz-deleted-long-ago/base/deployment.yaml',
		    'class': 'gap', 'reason': 'mutation probe', 'applied_by': 'nothing'})
		yaml.safe_dump(doc, open(path, 'w'))
	PY

	run python3 "$GATE"
	[ "$status" -ne 0 ]
	[[ "$output" == *"STALE EXCEPTION"* ]]
	[[ "$output" == *"zz-deleted-long-ago"* ]]
}

@test "5. MUTATION an exception for a manifest Flux DOES reconcile FAILS as stale" {
	# Pre-authorising a Flux-managed path would let a future regression hide behind
	# an entry that was already true. signal-ingest is reconciled by the
	# fe-signalloom `apps` Kustomization.
	local managed="d2-signalloom/apps/signal-ingest/base/deployment.yaml"
	test -f "${REPO_ROOT}/${managed}"

	python3 - "$EXC" "$managed" <<-'PY'
		import sys, yaml
		path, managed = sys.argv[1], sys.argv[2]
		doc = yaml.safe_load(open(path))
		doc['exceptions'].append({'path': managed, 'class': 'gap',
		                          'reason': 'mutation probe', 'applied_by': 'nothing'})
		yaml.safe_dump(doc, open(path, 'w'))
	PY

	run python3 "$GATE"
	[ "$status" -ne 0 ]
	[[ "$output" == *"STALE EXCEPTION: ${managed}"* ]]
}

@test "6. MUTATION an exception with no reason FAILS as malformed" {
	# An entry is only an exception if it says why. A bare path is a waiver.
	python3 - "$EXC" <<-'PY'
		import sys, yaml
		path = sys.argv[1]
		doc = yaml.safe_load(open(path))
		doc['exceptions'][0].pop('reason', None)
		yaml.safe_dump(doc, open(path, 'w'))
	PY

	run python3 "$GATE"
	[ "$status" -ne 0 ]
	[[ "$output" == *"MALFORMED EXCEPTION"* ]]
	[[ "$output" == *"missing: reason"* ]]
}

@test "7. \${ENVIRONMENT} comes from flux-runtime-info, not the cluster directory name" {
	# This is the mechanism, not just its effect. prod-eu and prod-us both set
	# ENVIRONMENT=production; a resolver that assumes the directory name
	# fabricates 16 dangling paths (./controllers/prod-eu etc. do not exist) and
	# reports a working fleet as broken. Asserting the resolver directly rather
	# than mutating a reconciled ConfigMap keeps this suite unable to publish a
	# mutated fleet.
	run python3 - "$REPO_ROOT" <<-'PY'
		import importlib.util, os, sys
		root = sys.argv[1]
		os.chdir(root)
		spec = importlib.util.spec_from_file_location(
		    'fwc', os.path.join(root, 'scripts', 'flux-workload-coverage.py'))
		mod = importlib.util.module_from_spec(spec)
		spec.loader.exec_module(mod)
		for cluster, expected in (('prod-eu', 'production'),
		                          ('prod-us', 'production'),
		                          ('staging', 'staging'),
		                          ('local', 'local')):
		    got = mod.cluster_environment(cluster)
		    assert got == expected, '%s -> %s, expected %s' % (cluster, got, expected)
		# and the naive reading really would be wrong
		assert not os.path.isdir('d2-infra/components/cert-manager/controllers/prod-eu')
		assert os.path.isdir('d2-infra/components/cert-manager/controllers/production')
		print('ok')
	PY
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]]
}

@test "8. no Flux Kustomization resolves to a path that does not exist" {
	# A Kustomization whose spec.path is absent reconciles nothing and still
	# reports Ready=True, which is indistinguishable from success.
	run python3 "$GATE" --json
	[ "$status" -eq 0 ]
	run python3 -c "import json,subprocess,sys; d=json.loads(subprocess.run([sys.executable,'$GATE','--json'],capture_output=True,text=True).stdout); print(len(d['dangling_paths']), len(d['resolution_problems']))"
	[ "$output" = "0 0" ]
}

@test "9. every OCI artifact a ResourceSet references has a known source directory" {
	# An artifact nothing publishes can never satisfy its OCIRepository. The
	# map in the gate is the single place that knowledge lives, so a new
	# artifact fails here as `unmapped-artifact` rather than resolving silently.
	run python3 "$GATE" --json
	[ "$status" -eq 0 ]
	[[ "$output" != *"unmapped-artifact"* ]]
	[[ "$output" != *"no-prefix-match"* ]]
}

@test "10. the register records the declared-gap count so it cannot drift unnoticed" {
	# Not an upper bound on quality -- an explicit number, so closing a gap or
	# admitting a new one is a visible diff rather than a silent reclassification.
	run python3 -c "import json,subprocess,sys; d=json.loads(subprocess.run([sys.executable,'$GATE','--json'],capture_output=True,text=True).stdout); print(len(d['declared_gaps']))"
	[ "$output" = "10" ]
}
