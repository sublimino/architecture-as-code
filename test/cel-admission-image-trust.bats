#!/usr/bin/env bats
#
# OSD-7: the appliance's image-trust admission gate is a CEL
# ValidatingAdmissionPolicy evaluated by the API server, not a Kyverno
# ClusterPolicy evaluated by a controller the bundle never shipped.
#
# The Kyverno path could not have worked air-gapped and was never wired up:
# `policy/kyverno-verify-images.yaml` was delivered by no Kustomization and
# no ResourceSet -- only imperatively by scripts/admission-demo.sh, which
# fetched Kyverno's install.yaml from a GitHub release URL. No admission
# controller appears in any of the 30 entries of
# bundle/.manifest.d/images.json, so the P2-4 / D4 deliverable "a
# digest-pinned platform image is admitted and an untrusted one rejected"
# was unsatisfiable as built.
#
# These checks are offline and structural. The CEL itself is EVALUATED for
# real -- against the exact pod shapes, through cel-go with the API
# server's optional-types environment -- by the Go suite this file's last
# test runs. Structural assertions alone would not catch a policy whose
# expression admits everything, which is why that delegation is here and
# not optional.
#
# @target policy/cel/require-trusted-registry.yaml
# @target policy/cel/require-image-digest.yaml
# @target policy/cel/admission-demo-bindings.yaml
# @target scripts/admission-demo.sh
# @tests  d2-signalloom/apps/fleet-manager/image_trust_vap_test.go
# @doc    docs/signalloom/image-verification-without-kyverno.md

bats_require_minimum_version 1.5.0

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	DEMO="$REPO_ROOT/scripts/admission-demo.sh"
	REGISTRY_POLICY="$REPO_ROOT/policy/cel/require-trusted-registry.yaml"
	DIGEST_POLICY="$REPO_ROOT/policy/cel/require-image-digest.yaml"
	DEMO_BINDINGS="$REPO_ROOT/policy/cel/admission-demo-bindings.yaml"
}

# code_of strips whole-line `#` comments so assertions about what a file
# DOES are not satisfied, or broken, by prose about what it USED to do.
# Both files here deliberately document the Kyverno path they replaced and
# the broken CEL form they fixed; a naive grep matches that documentation
# and reports the defect as still present. Measured: four of this suite's
# assertions failed that way on first run.
code_of() {
	grep -v '^[[:space:]]*#' "$1"
}

@test "the Kyverno ClusterPolicy is gone from the repo" {
	[ ! -e "$REPO_ROOT/policy/kyverno-verify-images.yaml" ]
}

@test "nothing operative still applies or includes the deleted Kyverno policy path" {
	# A dangling OPERATIVE reference is worse than the file itself: a
	# script or Kustomization naming a path that no longer exists fails at
	# the point of use -- in a demo, in front of a design partner. Prose
	# that records the removal is correct and must stay, so this checks
	# executable and manifest surfaces only, with comments stripped.
	cd "$REPO_ROOT"
	local hits=""
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		if code_of "$f" | grep -q -F 'kyverno-verify-images'; then
			hits="$hits$f"$'\n'
		fi
	done < <(git ls-files -- 'scripts/*' 'Makefile' '*.yaml' '*.yml' 'ui/*.json' 'bundle/*')
	[ -z "$hits" ] || {
		echo "the deleted policy is still operatively referenced by:"
		echo "$hits"
		false
	}
}

@test "the admission demo installs no admission controller and fetches nothing from the network" {
	[ -f "$DEMO" ]

	# The two things that made the old demo impossible air-gapped: an
	# install.yaml fetched from a GitHub release, and a controller rollout
	# to wait on. Both must be absent.
	run bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -n -F "github.com/kyverno"' _ "$DEMO"
	[ "$status" -ne 0 ]

	# No `kubectl apply -f <url>` anywhere: that is the air-gap breaker,
	# whatever it is fetching.
	run bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -nE "kubectl apply.*-f[[:space:]]+\"?https?://"' _ "$DEMO"
	[ "$status" -ne 0 ]

	run bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -n -F "wait_rollout kyverno"' _ "$DEMO"
	[ "$status" -ne 0 ]
}

@test "the admission demo applies the CEL policies and their demo bindings" {
	for f in \
		'policy/cel/require-trusted-registry.yaml' \
		'policy/cel/require-image-digest.yaml' \
		'policy/cel/admission-demo-bindings.yaml'
	do
		run grep -n -F -- "kubectl apply -f $f" "$DEMO"
		[ "$status" -eq 0 ] || {
			echo "scripts/admission-demo.sh never applies $f"
			false
		}
	done
}

@test "the admission demo proves enforcement is live before trusting any verdict" {
	# The API server compiles policies and caches bindings asynchronously.
	# A pod create that races ahead of enforcement is ADMITTED, so without
	# a probe that a known-bad pod is actually refused, the two denial
	# cases below could both pass vacuously on a slow control plane -- the
	# demo would report success having proven nothing.
	run grep -n -F 'admission enforcement is live' "$DEMO"
	[ "$status" -eq 0 ]
	run grep -n -F -- '--dry-run=server' "$DEMO"
	[ "$status" -eq 0 ]
}

@test "the demo asserts all three verdicts, not just the admission" {
	run grep -c -E '^[[:space:]]*(admitted|denied_untrusted|denied_unpinned)=0$' "$DEMO"
	[ "$status" -eq 0 ]
	[ "$output" -eq 3 ]

	# And the final gate must require all three. A gate on the admission
	# alone would pass while both denials silently regressed to admits.
	run grep -n -F '[ "${admitted}" -eq 0 ] && [ "${denied_untrusted}" -eq 0 ] && [ "${denied_unpinned}" -eq 0 ]' "$DEMO"
	[ "$status" -eq 0 ]
}

@test "every policy and binding is a native Kubernetes admission resource, not a Kyverno CRD" {
	for f in "$REGISTRY_POLICY" "$DIGEST_POLICY" "$DEMO_BINDINGS"; do
		# Every apiVersion in these files must be the native group. A
		# policies.kyverno.io or kyverno.io apiVersion here would apply to
		# nothing on a cluster with no Kyverno CRDs -- and would do so
		# SILENTLY, which is the failure this assertion exists to catch.
		run yq -N 'select(.apiVersion != null) | .apiVersion' "$f"
		[ "$status" -eq 0 ]
		[ -n "$output" ]
		while IFS= read -r ver; do
			[ "$ver" = "admissionregistration.k8s.io/v1" ] || {
				echo "$f declares apiVersion $ver"
				false
			}
		done <<<"$output"
	done
}

@test "the demo bindings Deny, and are scoped to the demo namespace by name" {
	run yq -N 'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.validationActions[0]' "$DEMO_BINDINGS"
	[ "$status" -eq 0 ]
	[ -n "$output" ]
	while IFS= read -r action; do
		[ "$action" = "Deny" ]
	done <<<"$output"

	# Selected by kubernetes.io/metadata.name, NOT by the platform's
	# signalloom.io/image-policy label: a demo must not be able to widen
	# enforcement onto a platform namespace, and a platform namespace must
	# not pick up the demo's harder Deny by acquiring a label.
	run yq -N 'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.matchResources.namespaceSelector.matchLabels["kubernetes.io/metadata.name"]' "$DEMO_BINDINGS"
	[ "$status" -eq 0 ]
	while IFS= read -r ns; do
		[ "$ns" = "admission-demo" ]
	done <<<"$output"
}

@test "the platform-wide digest binding is still Warn: the demo did not reprice a published risk posture" {
	# policy/cel/require-image-digest.yaml binds Warn platform-wide on
	# purpose -- it is a lane-keeping control whose residual is priced in
	# risk/ and published in docs/policy-as-versioned-code/INTEGRATION.md.
	# Promoting it to Deny to make the demo pass would silently change the
	# enforcement posture of every namespace carrying
	# signalloom.io/image-policy=enforced. The demo got its own binding
	# instead, and this test is what stops a future shortcut.
	run yq -N 'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.validationActions[0]' "$DIGEST_POLICY"
	[ "$status" -eq 0 ]
	[ "$output" = "Warn" ]
}

@test "the trusted-registry policy guards absent initContainers with optional field selection" {
	# `object.spec.initContainers.orValue([])` COMPILES and then fails at
	# EVAL with `no such key: initContainers` on any pod declaring none --
	# .orValue() is a method on an optional, and plain selection of an
	# absent key errors before it is reached. With failurePolicy: Fail
	# that rejected every ordinary pod in any enforced namespace: an
	# outage, not a guardrail. The `?` is the whole fix.
	run bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -n -F "object.spec.?initContainers.orValue([])"' _ "$REGISTRY_POLICY"
	[ "$status" -eq 0 ]

	# The broken form must be absent from the EXPRESSION. It is still named
	# in this file's comments, on purpose, so the next author does not
	# reintroduce it -- hence the comment strip.
	run bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -n -F "object.spec.initContainers.orValue([])"' _ "$REGISTRY_POLICY"
	[ "$status" -ne 0 ]
}

@test "the policies' own CEL admits a digest-pinned platform image and rejects an untrusted one" {
	# The real evaluation: cel-go, the API server's optional-types
	# environment, the exact pod shapes. Everything above is structure.
	run env CGO_ENABLED=0 go test -C "$REPO_ROOT/d2-signalloom/apps/fleet-manager" \
		-count=1 -run '^TestImageTrustVAP_' .
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "^ok"
}
