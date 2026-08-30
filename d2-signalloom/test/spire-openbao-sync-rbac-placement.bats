#!/usr/bin/env bats
#
# No RoleBinding may be authored in a Flux Kustomization slice that reconciles
# as the namespace-scoped `flux` ServiceAccount.
#
# ── The deadlock ──────────────────────────────────────────────────────────
#
# Those slices reconcile as `flux`, which holds ClusterRole/admin but NOT
# `escalate` on roles. Creating a RoleBinding therefore makes the API server
# resolve its roleRef to run the privilege-escalation check — and
# kustomize-controller server-dry-runs the ENTIRE object set to build its change
# set BEFORE applying any of it. A dry run never persists the Role, so the
# RoleBinding fails the lookup with
#
#   RoleBinding/<ns>/<name> not found
#
# which aborts the whole set. The Role is never applied for real, so every later
# reconcile fails identically. It is a deadlock, not a race: retrying cannot
# resolve it, and the slice freezes at the last revision that predated the file.
#
# ── Why this is a test and not a comment ──────────────────────────────────
#
# It has happened twice. First supercred-demo-runner-agents, which left
# fe-signalloom empty for six consecutive reconciles over twenty minutes and
# took the dashboard, the API and pipeline stages 6-8 down. It was diagnosed at
# length, and the write-up lives at the Role in
# d2-osramp-fleet/tenants/local/signalloom.yaml.
#
# Then spire-openbao-sync-cronjob.yaml did it again, and the write-up did not
# stop it — a comment on the object that got it RIGHT cannot be seen by someone
# authoring a new file somewhere else. That is the difference between
# documentation and a guard, and it cost the whole inf-bao slice: nine objects
# across three files never applied, including the CronJob that performs the 20h
# SPIRE→OpenBao JWT re-sync, so the very outage that CronJob exists to prevent
# was unguarded. inf-bao/infra-configs blocked behind it on dependsOn, and the
# agent-trust ResourceSet behind that. Measured 2026-08-30: the namespace had
# been frozen for so long that its live objects still matched a superseded
# revision.
#
# ── Scope ─────────────────────────────────────────────────────────────────
#
# The rule is about WHERE a binding is declared, so this scans the infra/apps
# manifest trees generically rather than naming known files. A new slice added
# tomorrow is covered without anyone remembering to list it — the omits-by-
# default failure that d2-signalloom/test/bats-registry-coverage.bats exists to
# end, applied to manifests instead of suites.
#
# ResourceSets are exempt and that is the entire point: the flux-operator
# applies them as the cluster-admin flux-system ServiceAccount, which skips the
# escalation check, in any order.

setup() {
	root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
	fleet="$root/d2-osramp-fleet/tenants/local/signalloom.yaml"
	sync_manifest="$root/d2-signalloom/infra/inf-bao/controllers/base/spire-openbao-sync-cronjob.yaml"
}

# The slice directories reconciled by the namespace-scoped `flux` ServiceAccount.
#
# Scope matters, and getting it wrong in the permissive direction is the whole
# risk here. A first draft flagged every RoleBinding under infra/ and apps/ and
# named six innocent files, because two other trees exist that this rule does
# NOT govern:
#
#   * d2-signalloom/infra/{agent-swarm,kagent}/ are not under any `flux`
#     Kustomization's path — they are delivered by other mechanisms with other
#     identities, so the escalation check never applies to them;
#   * apps/fe-signalloom/base/health-rbac.yaml declares a RoleBinding whose
#     roleRef is satisfied by a ResourceSet. That is the CORRECT pattern, and a
#     rule that reports it teaches people to ignore the rule.
#
# Verified against the live cluster: `kubectl get kustomization -A -o
# custom-columns=SA:.spec.serviceAccountName,PATH:.spec.path` shows `flux` on
# exactly the inf-*/controllers, inf-*/configs and fe-signalloom slices below.
flux_slices() {
	local d
	for d in \
		"$root/d2-signalloom/infra/inf-bao" \
		"$root/d2-signalloom/infra/inf-signalloom" \
		"$root/d2-signalloom/apps/fe-signalloom"; do
		[ -d "$d" ] && printf '%s\n' "$d"
	done
}

@test "the slice scan resolves real directories" {
	# Mechanism-presence check. If discovery returns nothing, the scan below
	# passes over an empty set — a guard against a deadlock, deadlocked on its
	# own emptiness.
	run flux_slices
	[ "$status" -eq 0 ]
	[ -n "$output" ]
	[ "$(wc -l <<<"$output")" -eq 3 ]
}

@test "no flux-reconciled slice binds a Role it also declares" {
	# The precise deadlock condition. A RoleBinding is fine on its own — the
	# roleRef resolves against a Role that already exists, typically from a
	# ResourceSet. It is declaring BOTH in one change set that hangs, because
	# the dry run that validates the binding runs before the Role is persisted.
	offenders=""
	while IFS= read -r slice; do
		[ -n "$slice" ] || continue
		roles=""; refs=""
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			# A genuine YAML syntax error is reported, not skipped — silence
			# is not evidence of compliance. The `!!map` guard is what keeps
			# that honest: without it, any document whose root is a sequence
			# makes yq fail with "cannot index array with 'kind'", which is
			# indistinguishable from a broken file. netassert-signalloom.yaml
			# is exactly that shape — a test config, not a manifest — and it
			# was reported as an offender until this guard was added. A rule
			# that cries wolf on a legitimate non-manifest is a rule people
			# switch off.
			out="$(yq -N -r 'select((. | type) == "!!map") | [.kind, (.metadata.name // ""), (.roleRef.name // "")] | @tsv' "$f" 2>/dev/null)" || {
				offenders="${offenders}  ${f#"$root"/} (unparseable)"$'\n'
				continue
			}
			while IFS=$'\t' read -r kind name ref; do
				case "$kind" in
					Role|ClusterRole) [ -n "$name" ] && roles="${roles}${name}"$'\n' ;;
					RoleBinding|ClusterRoleBinding) [ -n "$ref" ] && refs="${refs}${ref}"$'\n' ;;
				esac
			done < <(sed '/^[[:space:]]*$/d' <<<"$out")
		done < <(find "$slice" -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort)

		while IFS= read -r ref; do
			[ -n "$ref" ] || continue
			grep -qxF "$ref" <<<"$roles" && \
				offenders="${offenders}  ${slice#"$root"/} binds and declares '${ref}'"$'\n'
		done < <(sed '/^[[:space:]]*$/d' <<<"$refs" | sort -u)
	done < <(flux_slices)

	if [ -n "$offenders" ]; then
		echo "A binding and the role it references are declared in the same slice:"
		echo "$offenders"
		echo "These slices reconcile as the namespace-scoped 'flux' ServiceAccount, which"
		echo "lacks 'escalate' on roles. kustomize-controller server-dry-runs the whole"
		echo "object set before applying any of it, and a dry run never persists the Role,"
		echo "so the roleRef lookup fails and the ENTIRE slice aborts — permanently."
		echo "Move the ServiceAccount, Role and RoleBinding into a ResourceSet in"
		echo "d2-osramp-fleet/tenants/local/signalloom.yaml, leaving the workload behind."
	fi
	[ -z "$offenders" ]
}

@test "spire-openbao-sync RBAC lives in the signalloom-spire-rbac ResourceSet" {
	# The positive half. The scan above only proves the RBAC is absent from the
	# slice; absent from BOTH places is a CronJob with no identity, which fails
	# at runtime instead of at reconcile — quieter, and worse.
	for kind in ServiceAccount Role RoleBinding; do
		run env K="$kind" yq ea -N -r '
			select(.kind == "ResourceSet" and .metadata.name == "signalloom-spire-rbac")
			| .spec.resources[]
			| select(.kind == strenv(K) and .metadata.name == "spire-openbao-sync")
			| .metadata.namespace' "$fleet"
		[ "$status" -eq 0 ]
		[ "$(sed '/^[[:space:]]*$/d' <<<"$output")" = "inf-bao" ]
	done
}

@test "the spire-openbao-sync RoleBinding binds the ServiceAccount that the CronJob runs as" {
	# RBAC does not validate subjects: a binding naming a ServiceAccount that
	# does not exist applies cleanly and reports healthy, leaving the workload
	# with no authority and no warning anywhere. Splitting the RBAC away from
	# the workload makes that drift easy, so the two halves are tied together
	# here — this is the assertion that earns the split its keep.
	run yq ea -N -r '
		select(.kind == "ResourceSet" and .metadata.name == "signalloom-spire-rbac")
		| .spec.resources[]
		| select(.kind == "RoleBinding" and .metadata.name == "spire-openbao-sync")
		| [(.subjects[0].kind), (.subjects[0].name), (.subjects[0].namespace), (.roleRef.kind), (.roleRef.name)]
		| @tsv' "$fleet"
	[ "$status" -eq 0 ]
	[ "$(sed '/^[[:space:]]*$/d' <<<"$output")" = $'ServiceAccount\tspire-openbao-sync\tinf-bao\tRole\tspire-openbao-sync' ]

	run yq -N -r '
		select(.kind == "CronJob" and .metadata.name == "spire-openbao-sync")
		| .spec.jobTemplate.spec.template.spec.serviceAccountName' "$sync_manifest"
	[ "$status" -eq 0 ]
	[ "$(sed '/^[[:space:]]*$/d' <<<"$output")" = "spire-openbao-sync" ]
}

@test "the CronJob and its script stay in the controllers slice" {
	# The complement: only the RBAC moved. If the CronJob drifts into the
	# ResourceSet too it stops being reconciled with the config it reads, and
	# the ResourceSet becomes a second place to look for workloads.
	run yq -N -r 'select(.kind == "CronJob" or .kind == "ConfigMap") | .metadata.name' "$sync_manifest"
	[ "$status" -eq 0 ]
	names="$(sed '/^[[:space:]]*$/d' <<<"$output" | sort | tr '\n' ' ')"
	[ "$names" = "spire-openbao-sync spire-openbao-sync-script " ]
}
