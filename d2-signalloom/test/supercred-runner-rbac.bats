#!/usr/bin/env bats
#
# The SuperCred runner's RBAC subjects must name the namespace the runner
# actually runs in.
#
# The defect, observed 2026-08-03 on a live cluster: "Reset demo" (step 5)
# failed in 333 milliseconds with exit 1 and no error text, having printed only
# its banner. `bash -x` in the runner pod showed it dying at
# `spire_pod=$(spire_pod)` on:
#
#   pods is forbidden: User "system:serviceaccount:fe-signalloom:supercred-demo-runner"
#   cannot list resource "pods" in ... namespace "inf-bao"
#
# under `set -euo pipefail`. The runner held NONE of its cross-namespace
# grants. Every Role existed, every RoleBinding existed, Flux reported Ready --
# and every binding's subject was
# `ServiceAccount/inf-bao:supercred-demo-runner`, a ServiceAccount that has
# never existed. The real one is in fe-signalloom.
#
# Cause: the bindings are declared by the signalloom-infra ResourceSet, which
# is activated with TWO inputs whose `tenant` is inf-bao and inf-signalloom --
# the two INFRA namespaces. The subject was templated `<< inputs.tenant >>`, so
# it could only ever resolve to an infra namespace, while the runner's
# ServiceAccount is created by signalloom-apps in the APPS tenant.
#
# What makes this worth a static test:
#
#   1. RBAC does not validate subjects. A RoleBinding naming a ServiceAccount
#      that does not exist is a legal, healthy object. There is no event, no
#      warning, and no non-Ready condition anywhere -- the only symptom is a
#      403 at the far end, in a script, at demo time.
#   2. It is invisible to `kubectl get`/`describe` on the Roles, which are all
#      correct. Reviewing the verb lists (which is what least-privilege.bats
#      does) passes cleanly on a completely disarmed ServiceAccount.
#   3. The template renders TWICE, once per infra input, and the two renderings
#      collide on identical object names. Which of the two wrong namespaces
#      ends up applied is decided by apply order.
#
# So: render the ResourceSet the way Flux does -- against the real inputs from
# scripts/signalloom-local.sh -- and assert every subject naming the runner
# resolves to the namespace the runner's own workload is deployed into.
# Asserting the literal string "fe-signalloom" would go green on a tenant
# rename that moved the workload and left the grants behind, which is this bug
# again in a different hat.

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
	canonical="$repo_root/d2-osramp-fleet/tenants/local/signalloom.yaml"
	lifecycle="$repo_root/scripts/signalloom-local.sh"
	apps_kustomization="$repo_root/d2-signalloom/apps/fe-signalloom/base/kustomization.yaml"

	command -v yq >/dev/null || skip "yq is required to read the fleet ResourceSets"
	command -v jq >/dev/null || skip "jq is required to read the activation inputs"
	[ -f "$canonical" ]
	[ -f "$lifecycle" ]
}

# The inputs `make demo-signalloom-up` patches into a ResourceSet, taken from
# the activation call itself rather than restated here -- a copy would drift.
inputs_for() {
	sed -n "s/^[[:space:]]*activate_resourceset $1 '\(.*\)'\$/\1/p" "$lifecycle"
}

# .spec.resources of one ResourceSet document, as JSON.
resources_for() {
	yq -o=json "select(.metadata.name == \"$1\") | .spec.resources" "$canonical"
}

# Render resources against one input object the way flux-operator does:
# substitute every `<< inputs.KEY >>` with that key's value.
render() {
	local json="$1" input="$2" key value
	while IFS=$'\t' read -r key value; do
		json="${json//<< inputs.$key >>/$value}"
	done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$input")
	printf '%s' "$json"
}

# Every namespace named as the subject of a runner grant, one per line.
runner_subject_namespaces() {
	jq -r '.[]
		| select(.kind == "RoleBinding" or .kind == "ClusterRoleBinding")
		| .subjects[]?
		| select(.kind == "ServiceAccount" and .name == "supercred-demo-runner")
		| .namespace' <<<"$1"
}

# The namespace the runner workload is deployed into: signalloom-apps' tenant,
# which is the apps Kustomization's targetNamespace.
apps_tenant() {
	inputs_for signalloom-apps | jq -r '.[0].tenant'
}

@test "SUPERCRED-RBAC the runner workload is deployed by the apps tenant" {
	# Establishes the premise the rest of the file rests on. If the runner ever
	# moves out of the apps kustomization, these assertions must be revisited
	# rather than silently continuing to compare against the wrong namespace.
	run grep -Fq -- '- ../../supercred-demo-runner/base' "$apps_kustomization"
	[ "$status" -eq 0 ]

	tenant="$(apps_tenant)"
	[ -n "$tenant" ]
	[ "$tenant" != "null" ]

	# The apps Kustomization places everything it composes in its own tenant.
	tns="$(resources_for signalloom-apps |
		jq -r '.[] | select(.kind == "Kustomization") | .spec.targetNamespace')"
	[ "$tns" = '<< inputs.tenant >>' ]
}

@test "SUPERCRED-RBAC every runner grant names the namespace the runner runs in" {
	tenant="$(apps_tenant)"
	infra="$(resources_for signalloom-infra)"
	total=0

	while read -r input; do
		[ -n "$input" ] || continue
		rendered="$(render "$infra" "$input")"

		# Non-vacuity: a query that matched nothing would pass every assertion
		# below without testing anything at all.
		count="$(runner_subject_namespaces "$rendered" | grep -c .)"
		[ "$count" -ge 5 ]
		total=$((total + count))

		while read -r ns; do
			if [ "$ns" != "$tenant" ]; then
				echo "runner grant names ServiceAccount namespace '$ns'," >&2
				echo "but the runner ServiceAccount lives in '$tenant'." >&2
				echo "This binding grants nothing. Rendered from input: $input" >&2
				return 1
			fi
		done < <(runner_subject_namespaces "$rendered")
	done < <(inputs_for signalloom-infra | jq -c '.[]')

	[ "$total" -ge 5 ]
}

@test "SUPERCRED-RBAC runner grants carry no unresolved template token" {
	# A mistyped input key renders literally, producing a namespace of
	# "<< inputs.appsTenat >>" -- which the API server rejects, but only at
	# apply time, and only for that one object.
	tenant="$(apps_tenant)"
	infra="$(resources_for signalloom-infra)"

	while read -r input; do
		[ -n "$input" ] || continue
		rendered="$(render "$infra" "$input")"
		runner_objects="$(jq -c '[.[]
			| select((.metadata.name // "") | startswith("supercred-demo-runner"))]' <<<"$rendered")"

		[ "$(jq -r 'length' <<<"$runner_objects")" -ge 6 ]

		if grep -q '<< *inputs\.' <<<"$runner_objects"; then
			echo "unresolved template token in runner RBAC: $runner_objects" >&2
			return 1
		fi
	done < <(inputs_for signalloom-infra | jq -c '.[]')

	[ -n "$tenant" ]
}

@test "SUPERCRED-RBAC the double render is idempotent, not last-write-wins" {
	# signalloom-infra renders its whole resource list once per input, and the
	# runner's objects have fixed names, so both renderings target the same
	# objects. Identical content makes that harmless; differing content makes
	# the applied result depend on ordering. That ordering dependence is what
	# shipped the wrong namespace without anyone being able to point at a
	# single wrong line.
	infra="$(resources_for signalloom-infra)"
	first=""

	while read -r input; do
		[ -n "$input" ] || continue
		rendered="$(render "$infra" "$input")"
		runner_objects="$(jq -S -c '[.[]
			| select((.metadata.name // "") | startswith("supercred-demo-runner"))]' <<<"$rendered")"

		if [ -z "$first" ]; then
			first="$runner_objects"
		else
			[ "$runner_objects" = "$first" ]
		fi
	done < <(inputs_for signalloom-infra | jq -c '.[]')

	[ -n "$first" ]
}

# ─── Namespace ordering ──────────────────────────────────────────────────────
#
# A ResourceSet that places objects into a namespace must also create that
# namespace, because nothing else guarantees it exists when this set runs.
#
# signalloom-infra reconciles BEFORE signalloom-apps, by design. Moving the
# runner's Role and RoleBinding into signalloom-infra (to dodge the
# privilege-escalation dry-run deadlock) put infra-owned objects into the APPS
# tenant namespace -- which, on a cluster built from nothing, does not exist
# yet when infra reconciles:
#
#   reconciliation failed: Role/fe-signalloom/supercred-demo-runner-agents
#   not found: namespaces "fe-signalloom" not found
#
# signalloom-infra then never goes Ready, infra-controllers is never created,
# and stage 6 waits 443s for a Kustomization that cannot arrive; stages 7 and 8
# fail behind it.
#
# This was invisible locally, where a long-lived cluster already had the
# namespace from an earlier run, and reproduced identically on BOTH CI VMs the
# first time the change met a fresh cluster. That asymmetry -- passes on the
# machine you develop on, fails on every clean one -- is exactly what a static
# test is for.

# Every namespace this set's own resources are placed into.
namespaces_used() {
	jq -r '.[] | select(.kind != "Namespace") | .metadata.namespace // empty' <<<"$1" | sort -u
}

# Every namespace this set creates.
namespaces_created() {
	jq -r '.[] | select(.kind == "Namespace") | .metadata.name' <<<"$1" | sort -u
}

# Namespaces the cluster always has. kube-system et al are created by the
# control plane before any Flux object exists, so writing into them is fine.
PREEXISTING_NAMESPACES="kube-system kube-public kube-node-lease default flux-system"

# Union of namespaces created across EVERY input, because the set renders once
# per input and input[1] creates the namespace input[0] happens to reference.
infra_namespaces_created_all() {
	local resources inputs i rendered
	resources="$(resources_for signalloom-infra)"
	inputs="$(inputs_for signalloom-infra)"
	for i in $(jq -r 'to_entries[].key' <<<"$inputs"); do
		rendered="$(render "$resources" "$(jq -c ".[$i]" <<<"$inputs")")"
		namespaces_created "$rendered"
	done | sort -u
}

infra_namespaces_used_all() {
	local resources inputs i rendered
	resources="$(resources_for signalloom-infra)"
	inputs="$(inputs_for signalloom-infra)"
	for i in $(jq -r 'to_entries[].key' <<<"$inputs"); do
		rendered="$(render "$resources" "$(jq -c ".[$i]" <<<"$inputs")")"
		namespaces_used "$rendered"
	done | sort -u
}

@test "SUPERCRED-RBAC signalloom-infra creates every namespace it writes into" {
	local created used ns missing=()
	created="$(infra_namespaces_created_all)"
	used="$(infra_namespaces_used_all)"

	while IFS= read -r ns; do
		[ -n "$ns" ] || continue
		# Skip namespaces the control plane guarantees.
		case " $PREEXISTING_NAMESPACES " in *" $ns "*) continue ;; esac
		grep -qx "$ns" <<<"$created" || missing+=("$ns")
	done <<<"$used"

	if ((${#missing[@]} > 0)); then
		echo "signalloom-infra places resources into namespaces it does not create:"
		printf '  %s\n' "${missing[@]}"
		echo "It reconciles before signalloom-apps, so on a fresh cluster these do not"
		echo "exist yet and the whole set fails with 'namespaces \"X\" not found'."
		return 1
	fi
}

@test "SUPERCRED-RBAC the apps tenant namespace is created by infra, not only by apps" {
	# The specific instance of the rule above, pinned by name so a future edit
	# that drops the Namespace fails with a message naming the actual cause.
	local rendered tenant
	rendered="$(render "$(resources_for signalloom-infra)" "$(inputs_for signalloom-infra | jq -c '.[0]')")"
	tenant="$(apps_tenant)"
	namespaces_created "$rendered" | grep -qx "$tenant" || {
		echo "signalloom-infra does not create the apps tenant namespace '$tenant',"
		echo "but it declares the runner's Role/RoleBinding into it and runs first."
		return 1
	}
}
