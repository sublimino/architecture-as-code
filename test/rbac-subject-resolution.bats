#!/usr/bin/env bats
#
# A RoleBinding whose ServiceAccount does not exist is legal, silent, and grants
# nothing. So is one whose roleRef names a Role nobody created. The API server
# stores both, Flux marks them Ready, and the only symptom is a workload getting
# 403 on a call it should be allowed to make -- which, in this estate, mostly
# surfaces as *fewer results* rather than as an error.
#
# scripts/check-rbac-subjects.py derives both sides. This suite runs it against
# the repository AND proves it fails on injected drift, because a checker that
# cannot fail is a checker that reports coverage it does not provide. Three of
# the tests below construct a broken fixture repo and assert a non-zero exit;
# without them the audit could silently degrade to "found nothing, all fine",
# which is the exact shape of several defects this repository has already paid
# for.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	CHECKER="${REPO_ROOT}/scripts/check-rbac-subjects.py"
	FIXTURE="${BATS_TEST_TMPDIR}/fixture"
}

# A minimal but VALID repo: one SA, one Role, one binding that resolves.
# Every negative test starts from this and breaks exactly one thing, so a
# failure is attributable to the injected defect and not to the scaffold.
make_valid_fixture() {
	mkdir -p "$FIXTURE"
	git -C "$FIXTURE" init -q 2>/dev/null || true
	cat >"$FIXTURE/rbac.yaml" <<-'YAML'
		apiVersion: v1
		kind: ServiceAccount
		metadata:
		  name: worker
		  namespace: demo
		---
		apiVersion: rbac.authorization.k8s.io/v1
		kind: Role
		metadata:
		  name: pod-reader
		  namespace: demo
		rules:
		  - apiGroups: [""]
		    resources: ["pods"]
		    verbs: ["get", "list"]
		---
		apiVersion: rbac.authorization.k8s.io/v1
		kind: RoleBinding
		metadata:
		  name: worker-reads-pods
		  namespace: demo
		roleRef:
		  apiGroup: rbac.authorization.k8s.io
		  kind: Role
		  name: pod-reader
		subjects:
		  - kind: ServiceAccount
		    name: worker
		    namespace: demo
	YAML
	git -C "$FIXTURE" add -A
}

@test "RBAC the checker exists and is executable" {
	[ -f "$CHECKER" ]
	[ -x "$CHECKER" ]
}

@test "RBAC every binding in this repository resolves" {
	run python3 "$CHECKER" "$REPO_ROOT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"all resolve"* ]]
}

@test "RBAC the scan finds a non-empty universe" {
	# The load-bearing mechanism check. A scanner that reads zero bindings
	# passes the test above trivially: no subject can fail to resolve if no
	# subject was found. These floors are well below the current counts (48
	# subject uses, 20 ServiceAccounts) so they will not tighten on ordinary
	# change, but they do catch the scan collapsing to nothing.
	run python3 "$CHECKER" "$REPO_ROOT" --list
	[ "$status" -eq 0 ]

	local subjects accounts
	subjects="$(echo "$output" | awk '/binding subject uses/ {print $NF}')"
	accounts="$(echo "$output" | awk '/serviceaccounts declared/ {print $NF}')"
	[ -n "$subjects" ]
	[ "$subjects" -ge 10 ]
	[ "$accounts" -ge 5 ]
}

@test "RBAC nested ResourceSet resources are scanned, not just top-level docs" {
	# Not a nicety. Flux ResourceSets carry whole objects inline under
	# spec.resources[], and most of this estate's Roles are declared that way:
	# a top-level-only scan sees 2 Roles where there are 13, and reports
	# Role/fe-signalloom-health-reader as missing when it is declared at
	# d2-osramp-fleet/tenants/local/signalloom.yaml.
	#
	# That false positive is the dangerous outcome, not a harmless one -- the
	# obvious "fix" is a duplicate Role or an allowlist entry that blinds the
	# check permanently. This asserts the nested walk is present, so the
	# capability cannot be refactored away while the suite stays green.
	mkdir -p "$FIXTURE"
	git -C "$FIXTURE" init -q 2>/dev/null || true
	cat >"$FIXTURE/nested.yaml" <<-'YAML'
		apiVersion: fluxcd.controlplane.io/v1
		kind: ResourceSet
		metadata:
		  name: fleet
		spec:
		  resources:
		    - apiVersion: v1
		      kind: ServiceAccount
		      metadata:
		        name: nested-sa
		        namespace: demo
		---
		apiVersion: rbac.authorization.k8s.io/v1
		kind: ClusterRoleBinding
		metadata:
		  name: uses-nested
		roleRef:
		  apiGroup: rbac.authorization.k8s.io
		  kind: ClusterRole
		  name: view
		subjects:
		  - kind: ServiceAccount
		    name: nested-sa
		    namespace: demo
	YAML
	git -C "$FIXTURE" add -A

	run python3 "$CHECKER" "$FIXTURE"
	[ "$status" -eq 0 ]
}

@test "RBAC a binding naming an undeclared ServiceAccount fails the audit" {
	make_valid_fixture
	# One character of drift: the subject now names an account nothing creates.
	sed -i 's/^    name: worker$/    name: typo-worker/' "$FIXTURE/rbac.yaml"
	git -C "$FIXTURE" add -A

	run python3 "$CHECKER" "$FIXTURE"
	[ "$status" -eq 1 ]
	[[ "$output" == *"typo-worker"* ]]
	[[ "$output" == *"which no manifest creates"* ]]
}

@test "RBAC a binding referencing an undeclared Role fails the audit" {
	make_valid_fixture
	# FIRST occurrence only: that is the Role's own metadata.name. The roleRef
	# further down keeps pointing at `pod-reader`, which now exists nowhere.
	# Renaming both -- which a bare `sed s/.../.../` does, since the two lines
	# are identical at the same indent -- leaves the fixture perfectly
	# consistent and injects no drift at all. The first version of this test did
	# exactly that and reported the checker as broken when it was correct.
	sed -i '0,/^  name: pod-reader$/s//  name: renamed-pod-reader/' "$FIXTURE/rbac.yaml"
	git -C "$FIXTURE" add -A

	run python3 "$CHECKER" "$FIXTURE"
	[ "$status" -eq 1 ]
	[[ "$output" == *"pod-reader"* ]]
	[[ "$output" == *"confers no permissions"* ]]
}

@test "RBAC an empty scan is a failure, not a pass" {
	# The vacuous-success case, asserted directly. A repository with no
	# bindings must not report "ok" -- when this checker runs against the real
	# tree, an empty result means the scanner broke, and the one thing it must
	# never do is call that success.
	mkdir -p "$FIXTURE"
	git -C "$FIXTURE" init -q 2>/dev/null || true
	echo "# no rbac here" >"$FIXTURE/empty.yaml"
	git -C "$FIXTURE" add -A

	run python3 "$CHECKER" "$FIXTURE"
	[ "$status" -eq 1 ]
	[[ "$output" == *"scanner is broken"* ]]
}

@test "RBAC the default ServiceAccount is allowed without a declaration" {
	# Kubernetes creates `default` in every namespace, so bindings naming it
	# resolve at runtime with no manifest. This exemption is real and in use
	# (two bindings in this repo rely on it); it is asserted so that tightening
	# the rule cannot quietly turn working manifests red.
	mkdir -p "$FIXTURE"
	git -C "$FIXTURE" init -q 2>/dev/null || true
	cat >"$FIXTURE/default-sa.yaml" <<-'YAML'
		apiVersion: v1
		kind: ServiceAccount
		metadata:
		  name: someone
		  namespace: demo
		---
		apiVersion: rbac.authorization.k8s.io/v1
		kind: ClusterRoleBinding
		metadata:
		  name: default-reads
		roleRef:
		  apiGroup: rbac.authorization.k8s.io
		  kind: ClusterRole
		  name: view
		subjects:
		  - kind: ServiceAccount
		    name: default
		    namespace: demo
	YAML
	git -C "$FIXTURE" add -A

	run python3 "$CHECKER" "$FIXTURE"
	[ "$status" -eq 0 ]
}
