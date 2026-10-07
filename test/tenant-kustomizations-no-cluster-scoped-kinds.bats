#!/usr/bin/env bats
#
# Regression guard for the defect a live deploy found in sldc/sa-identity:
# fe-signalloom's `apps` Kustomization is reconciled by the TENANT
# ServiceAccount system:serviceaccount:fe-signalloom:flux (bound to the
# namespaced ClusterRole `admin` via a RoleBinding, not cluster-admin --
# see d2-osramp-fleet/tenants/base/apps.yaml), which has no RBAC to patch
# cluster-scoped resources. A ValidatingAdmissionPolicy committed into that
# Kustomization's resource tree made the WHOLE `apps` dry-run apply fail,
# taking down everything else in it.
#
# This renders every tenant-reconciled Kustomization path offline (`kubectl
# kustomize`, no cluster, no apply) and asserts none of them contains a
# cluster-scoped kind the tenant reconciler is not separately, deliberately
# RBAC'd for. Any future commit that repeats the same mistake -- for ANY of
# these kinds, in ANY of these trees -- fails here before it reaches a live
# cluster.
#
# One documented exception: agent-swarm's root Kustomization (path: ".")
# legitimately renders a Namespace (d2-signalloom/infra/agent-swarm/
# namespace.yaml). Its tenant SA, agent-swarm-flux, is deliberately granted
# a narrow ClusterRole for exactly that
# (d2-osramp-fleet/tenants/base/agent-swarm.yaml:
# agent-swarm-flux-namespaces -- create/get/list/watch namespaces
# cluster-wide, update/patch/delete scoped to resourceNames:
# [fe-signalloom-agents] only). That is a reviewed, audited exception (the
# same file documents a PRIOR over-broad grant that was removed), not the
# unreviewed accident this test exists to catch -- so it is allowlisted by
# name, for that one path only, not disabled for the kind everywhere.
#
# @target d2-signalloom/apps/fe-signalloom/base, d2-signalloom/infra/agent-swarm/*,
#         d2-signalloom/infra/inf-bao/{controllers,configs}/base,
#         d2-signalloom/infra/inf-signalloom/{controllers,configs}/base
# @doc    d2-osramp-fleet/tenants/base/{apps,agent-swarm,infra}.yaml

bats_require_minimum_version 1.5.0

# Kinds that are cluster-scoped in a stock Kubernetes + Flux install.
# ValidatingAdmissionPolicy/-Binding is the kind the incident was actually
# about; the rest are the same hazard class (a tenant Kustomization that
# somehow ends up carrying one of these will fail its dry-run apply, or
# worse, if the tenant SA DOES have RBAC for it, succeed and mutate
# cluster-wide state from a tenant-scoped reconciler).
CLUSTER_SCOPED_KINDS=(
	ValidatingAdmissionPolicy
	ValidatingAdmissionPolicyBinding
	MutatingAdmissionPolicy
	MutatingAdmissionPolicyBinding
	ClusterRole
	ClusterRoleBinding
	CSIDriver
	Namespace
	CustomResourceDefinition
	PriorityClass
	StorageClass
	APIService
)

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	AGENT_SWARM_RS="$REPO_ROOT/d2-osramp-fleet/tenants/base/agent-swarm.yaml"
}

# render_dir renders one Kustomization directory offline and fails the test
# immediately (not just "skip") if kubectl kustomize itself errors -- a
# directory that cannot render at all is not proof of "no cluster-scoped
# kinds", it is a different failure this test must not hide.
#
# --load-restrictor=LoadRestrictionsNone: this repo has at least one
# kustomization (inf-signalloom/controllers/base) whose configMapGenerator
# reads a file from outside its own root, which kustomize's default
# LoadRestrictionsRootOnly refuses. That restriction is about
# relocatability, not about which kinds get rendered, and is orthogonal to
# what this test checks; relaxing it here only affects this offline
# inspection, never what Flux's own kustomize-controller does on a real
# cluster.
render_dir() {
	local dir="$1"
	run env KUBECONFIG=/dev/null kubectl kustomize --load-restrictor=LoadRestrictionsNone "$dir"
	if [ "$status" -ne 0 ]; then
		echo "kubectl kustomize $dir failed (rc=$status):" >&2
		echo "$output" >&2
		return 1
	fi
	echo "$output"
}

# assert_no_cluster_scoped_kinds renders $2 (labelled $1 in failure output)
# and fails naming every forbidden kind found, not just the first -- so one
# run surfaces the whole problem rather than requiring N re-runs. $3, if
# given, is a space-separated allowlist of kinds this specific path is
# reviewed and RBAC'd for (see the file header for the one case that uses
# this).
assert_no_cluster_scoped_kinds() {
	local label="$1" dir="$2" allowed=" ${3:-} "
	local rendered
	rendered="$(render_dir "$dir")" || return 1

	local found=() kind
	for kind in "${CLUSTER_SCOPED_KINDS[@]}"; do
		case "$allowed" in
			*" $kind "*) continue ;;
		esac
		if printf '%s\n' "$rendered" | grep -qx "kind: ${kind}"; then
			found+=("$kind")
		fi
	done
	if [ "${#found[@]}" -ne 0 ]; then
		echo "$label ($dir) renders cluster-scoped kind(s) its tenant reconciler cannot apply: ${found[*]}" >&2
		return 1
	fi
}

@test "fe-signalloom apps (tenant SA: flux, RoleBinding to admin, apps.yaml) renders no cluster-scoped kind" {
	assert_no_cluster_scoped_kinds "fe-signalloom/apps" "$REPO_ROOT/d2-signalloom/apps/fe-signalloom/base"
}

@test "every agent-swarm tenant Kustomization path (tenant SA: agent-swarm-flux) renders no UNREVIEWED cluster-scoped kind" {
	# Discovered from the real Flux ResourceSet, not a parallel hardcoded
	# list that could drift from it: every "kind: Kustomization" entry in
	# agent-swarm.yaml uses serviceAccountName: agent-swarm-flux (verified
	# once, by inspection, when this test was written -- if a future entry
	# ever used a different, more-privileged SA, this test would still
	# render its path and could give a false failure; that would be the
	# correct prompt to split this test, not evidence the test is wrong).
	run yq -N '.spec.resources[] | select(.kind == "Kustomization") | .spec.path' "$AGENT_SWARM_RS"
	[ "$status" -eq 0 ]
	[ -n "$output" ]

	local failures=0
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		dir="$REPO_ROOT/d2-signalloom/infra/agent-swarm/${path#./}"
		dir="${dir%/.}"
		allowed=""
		# Only the root path -- the one that owns namespace.yaml -- carries
		# the reviewed Namespace exception documented in the file header.
		[ "$path" = "." ] && allowed="Namespace"
		if ! assert_no_cluster_scoped_kinds "agent-swarm${path#.}" "$dir" "$allowed"; then
			failures=$((failures + 1))
		fi
	done <<< "$output"
	[ "$failures" -eq 0 ]
}

@test "inf-bao tenant slices (controllers/base, configs/base) render no cluster-scoped kind" {
	assert_no_cluster_scoped_kinds "inf-bao/controllers/base" "$REPO_ROOT/d2-signalloom/infra/inf-bao/controllers/base"
	assert_no_cluster_scoped_kinds "inf-bao/configs/base" "$REPO_ROOT/d2-signalloom/infra/inf-bao/configs/base"
}

@test "inf-signalloom tenant slices (controllers/base, configs/base) render no cluster-scoped kind" {
	assert_no_cluster_scoped_kinds "inf-signalloom/controllers/base" "$REPO_ROOT/d2-signalloom/infra/inf-signalloom/controllers/base"
	assert_no_cluster_scoped_kinds "inf-signalloom/configs/base" "$REPO_ROOT/d2-signalloom/infra/inf-signalloom/configs/base"
}
