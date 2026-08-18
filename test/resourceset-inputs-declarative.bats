#!/usr/bin/env bats
#
# Every ResourceSet must be reconcilable FROM THE RENDERED MANIFEST ALONE.
#
# This models the cold cluster: nothing has run, nothing has patched anything,
# the only thing that exists is what `kubectl kustomize` emits. A ResourceSet
# that needs a script to run before Flux can build it is not a declarative
# object, and the cold path is the only condition that exposes it.
#
# ── The fundamental constraint ──────────────────────────────────────────────
#
# flux-operator renders spec.resources as a Go text/template with
# `Option("missingkey=error")` (internal/builder/resourceset.go, newTemplate).
# In BuildResourceSet:
#
#     for i, tmpl := range templates {
#         if len(combinedInputs) == 0 {
#             object, err := BuildResource(tmpl, nil)   // ← ONE pass, nil map
#             ...
#
# `inputs: []` therefore does NOT mean "render nothing". It means "render once
# with a nil input map", and every `<< inputs.K >>` in the template is then a
# hard error:
#
#     build failed: ... executing "resourceset" at <inputs>:
#       map has no entry for key "tenant"
#
# The controller routes that through stallWithTerminalError -- Stalled=True,
# no requeue, no retry. It never recovers on its own.
#
# The "empty inputs deploy nothing" behaviour the fleet has been assuming DOES
# exist, but the controller gates it on providers being in use
# (internal/controller/resourceset_controller.go):
#
#     if len(obj.Spec.InputsFrom) > 0 && len(inputSet) == 0 {
#         // If providers return no inputs, we should reconcile an empty set to trigger GC.
#     } else {
#         steps, buildErr = builder.BuildResourceSetFromSpec(obj.Spec, inputSet)
#
# With inputsFrom unset, `inputs: []` falls into the else branch and builds.
# So there are exactly three legal ways to ship a ResourceSet whose template
# dereferences an input key, and this file enforces that they are the only
# three:
#
#   (a) spec.inputs is non-empty and every entry supplies every referenced key
#   (b) spec.inputsFrom is set -- providers own the input set, empty is legal
#   (c) fluxcd.controlplane.io/reconcile: disabled -- the controller returns
#       before the build (resourceset_controller.go, obj.IsDisabled())
#
# Anything else is an object that ships permanently stalled and waits for a
# script to repair it. Which is the defect: the repair step for the Agent Trust
# slice ran behind a readiness gate that could not open until the repair had
# already happened.
#
# ── Why this is a static test ───────────────────────────────────────────────
#
# A cluster test cannot catch this without being built from nothing, because a
# warm cluster still carries the inputs a previous run patched in, so the gate
# opens and the repair step is reached. Three from-scratch CI runs were the
# only thing that ever saw it. The rendered manifest has the same information
# and needs no cluster at all.

setup() {
	root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
	command -v yq >/dev/null || skip "yq is required"
	command -v kubectl >/dev/null || skip "kubectl is required"
	rendered_dir="$BATS_TEST_TMPDIR/rendered"
	mkdir -p "$rendered_dir"
}

# Renders one fleet overlay to a single multi-doc file and echoes its path.
render_overlay() {
	local overlay="$1" out
	out="$rendered_dir/$(printf '%s' "$overlay" | tr '/' '_').yaml"
	kubectl kustomize --load-restrictor LoadRestrictionsNone \
		"$root/d2-osramp-fleet/tenants/$overlay" >"$out"
	printf '%s' "$out"
}

# Every fleet overlay a cluster actually points a Kustomization at.
# clusters/local/tenants.yaml    -> ./tenants/local
# clusters/{staging,prod-eu,prod-us}/tenants.yaml -> ./tenants/ghcr
overlays() { printf 'local\nghcr\n'; }

resourceset_names() {
	yq 'select(.kind == "ResourceSet") | .metadata.name' "$1"
}

# Keys the template dereferences, one per line, deduplicated.
# Matches `<< inputs.tenant >>` and any spacing variant of it.
referenced_keys() {
	local file="$1" name="$2"
	yq -o=json \
		"select(.kind == \"ResourceSet\" and .metadata.name == \"$name\") | [.spec.resources, .spec.resourcesTemplate]" \
		"$file" |
		grep -oE '<<[[:space:]]*inputs\.[A-Za-z0-9_]+' |
		sed 's/.*inputs\.//' | sort -u
}

rs_field() {
	local file="$1" name="$2" expr="$3"
	yq "select(.kind == \"ResourceSet\" and .metadata.name == \"$name\") | $expr" "$file"
}

# Emits one "<name>: <reason>" line per ResourceSet that cannot build, and
# returns 1 if there were any. Silence and 0 mean every object is reconcilable.
unbuildable_in() {
	local file="$1" name keys count inputs_from disabled i entry_keys key found bad=0

	while IFS= read -r name; do
		[ -n "$name" ] || continue
		keys="$(referenced_keys "$file" "$name")"
		[ -n "$keys" ] || continue # (no input refs -- inputs are irrelevant)

		# (c) explicitly disabled: the controller returns before the build.
		disabled="$(rs_field "$file" "$name" '.metadata.annotations."fluxcd.controlplane.io/reconcile" // ""')"
		[ "$disabled" = "disabled" ] && continue

		# (b) provider-driven: an empty input set is legal and triggers GC.
		inputs_from="$(rs_field "$file" "$name" '.spec.inputsFrom // [] | length')"
		[ "$inputs_from" -gt 0 ] && continue

		# (a) in-line inputs must exist and be complete.
		count="$(rs_field "$file" "$name" '.spec.inputs // [] | length')"
		if [ "$count" -eq 0 ]; then
			printf '%s: dereferences << inputs.%s >> but ships spec.inputs: [] with no inputsFrom and no disable annotation -- builds once against a nil map and stalls terminally\n' \
				"$name" "$(printf '%s' "$keys" | head -1)"
			bad=1
			continue
		fi

		i=0
		while [ "$i" -lt "$count" ]; do
			entry_keys="$(rs_field "$file" "$name" ".spec.inputs[$i] | keys | .[]")"
			while IFS= read -r key; do
				[ -n "$key" ] || continue
				found=0
				while IFS= read -r have; do
					[ "$have" = "$key" ] && found=1
				done <<<"$entry_keys"
				if [ "$found" -eq 0 ]; then
					printf '%s: spec.inputs[%d] is missing key %s which the template dereferences\n' \
						"$name" "$i" "$key"
					bad=1
				fi
			done <<<"$keys"
			i=$((i + 1))
		done
	done <<<"$(resourceset_names "$file")"

	return "$bad"
}

@test "RSD every ResourceSet in every fleet overlay can build with no cluster state" {
	local overlay file failures=0 out
	while IFS= read -r overlay; do
		file="$(render_overlay "$overlay")"
		if ! out="$(unbuildable_in "$file")"; then
			printf 'overlay tenants/%s:\n%s\n' "$overlay" "$out" >&2
			failures=1
		fi
	done <<<"$(overlays)"
	[ "$failures" -eq 0 ]
}

# The specific chain the cold CI runs failed on. Kept separate from the sweep
# above so a regression here names the Agent Trust slice rather than reporting
# a generic count, and so the sweep passing for the wrong reason (e.g. someone
# deletes agent-trust.yaml from the overlay) still fails this.
@test "RSD the local overlay ships the Agent Trust dependency chain ready to build" {
	local file
	file="$(render_overlay local)"

	local name
	for name in signalloom-infra signalloom-apps agent-trust; do
		run rs_field "$file" "$name" '.spec.inputs // [] | length'
		[ "$status" -eq 0 ]
		[ -n "$output" ]
		[ "$output" -gt 0 ] || {
			printf 'ResourceSet/%s ships spec.inputs: [] -- on a cold cluster it stalls\n' "$name" >&2
			printf 'with `map has no entry for key "tenant"`, and agent-trust never builds\n' >&2
			printf 'because its dependsOn on signalloom-infra can never go Ready.\n' >&2
			return 1
		}
	done

	# agent-trust depends on signalloom-infra, so a populated agent-trust behind
	# an empty signalloom-infra is still a dead chain. Assert the edge exists so
	# the three assertions above are known to be describing one graph.
	run rs_field "$file" agent-trust '.spec.dependsOn[] | select(.kind == "ResourceSet") | .name'
	[ "$status" -eq 0 ]
	[[ "$output" == *"signalloom-infra"* ]]
}

# Mutation check. The sweep above is exactly the kind of assertion that can go
# green while measuring nothing -- if referenced_keys silently returned empty
# for every object (a yq expression typo, a changed delimiter, a rename of
# spec.resources) the loop would `continue` past every ResourceSet and report
# success having examined none. This proves the detector fires.
@test "RSD the detector actually fails on a ResourceSet with empty inputs" {
	local file="$BATS_TEST_TMPDIR/injected.yaml"
	cat >"$file" <<'YAML'
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSet
metadata:
  name: canary
  namespace: flux-system
spec:
  inputs: []
  resources:
    - apiVersion: v1
      kind: Namespace
      metadata:
        name: << inputs.tenant >>
YAML
	run unbuildable_in "$file"
	[ "$status" -eq 1 ]
	[[ "$output" == *"canary"* ]]
	[[ "$output" == *"stalls terminally"* ]]
}

@test "RSD the detector accepts each of the three legal shapes" {
	local file="$BATS_TEST_TMPDIR/legal.yaml"
	cat >"$file" <<'YAML'
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSet
metadata:
  name: inline-complete
spec:
  inputs:
    - tenant: "a"
  resources:
    - {apiVersion: v1, kind: Namespace, metadata: {name: << inputs.tenant >>}}
---
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSet
metadata:
  name: provider-driven
spec:
  inputsFrom:
    - kind: ResourceSetInputProvider
      name: some-provider
  inputs: []
  resources:
    - {apiVersion: v1, kind: Namespace, metadata: {name: << inputs.tenant >>}}
---
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSet
metadata:
  name: explicitly-disabled
  annotations:
    fluxcd.controlplane.io/reconcile: disabled
spec:
  inputs: []
  resources:
    - {apiVersion: v1, kind: Namespace, metadata: {name: << inputs.tenant >>}}
---
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSet
metadata:
  name: no-input-refs
spec:
  resources:
    - {apiVersion: v1, kind: Namespace, metadata: {name: fixed}}
YAML
	run unbuildable_in "$file"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

# An incomplete input set is the quieter half of the same defect: the object
# has inputs, so every "is it activated" check passes, and it still stalls on
# the one key nobody supplied.
@test "RSD the detector fails on an input set missing one referenced key" {
	local file="$BATS_TEST_TMPDIR/partial.yaml"
	cat >"$file" <<'YAML'
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSet
metadata:
  name: partial
spec:
  inputs:
    - tenant: "a"
  resources:
    - apiVersion: v1
      kind: ConfigMap
      metadata:
        name: << inputs.tenant >>
        namespace: << inputs.component >>
YAML
	run unbuildable_in "$file"
	[ "$status" -eq 1 ]
	[[ "$output" == *"missing key component"* ]]
}
