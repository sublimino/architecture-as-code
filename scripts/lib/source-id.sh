#!/usr/bin/env bash
# source-id.sh — the ONE definition of "which source tree is this image built from".
#
# ─── Why this exists ────────────────────────────────────────────────────────
#
# On 2026-08-13 a streaming fix landed across 22 commits, was verified by 315
# backend tests, 1657 dashboard tests and a browser harness, and was reported as
# working. It did not work, because the pods answering the requests predated
# every one of those commits:
#
#   supercred-demo-runner  age 3h56m  ->  still running the original bug
#   dashboard-signalloom   age 138m   ->  bundle contained none of the fix
#
# Every test was green and every one of them tested the SOURCE TREE. Nothing
# tested what was RUNNING. There was no signal anywhere that said "the code you
# are reading is not the code answering your requests".
#
# It was the second instance of the class. The first is recorded in
# scripts/acceptance-test.sh's neighbourhood: that script does not rebuild, so a
# dashboard source fix is invisible to a spec until you rebuild and roll.
#
# ─── Why a content fingerprint, and not the obvious alternatives ────────────
#
# image tag      `supercred-demo-runner:local` and `...:latest` are MUTABLE.
#                They are byte-identical before and after a rebuild, so they
#                cannot distinguish the two states we care about. This is the
#                property that let the original failure hide.
#
# git SHA        Changes only on commit. Everything in this repo is edited and
#                rebuilt many times between commits, so a guard keyed on HEAD
#                reports "matching" for a working tree that has been modified
#                since the build — a vacuous pass, which is the exact failure
#                shape we are trying to remove. Kept as a DIAGNOSTIC below, but
#                never as the comparison.
#
# image digest   `pod.status.containerStatuses[].imageID` is sound for
#                supercred-demo-runner, which kind-loads a local build and
#                reports a bare `sha256:<config digest>` that
#                `docker image inspect --format '{{.Id}}'` reproduces. It is NOT
#                sound for the dashboard, which travels through the zot registry
#                and reports `docker.io/library/import-2026-08-13@sha256:…` —
#                a registry manifest digest with no derivable relationship to
#                the local daemon's config digest. It also requires the building
#                daemon to still hold the image. Non-uniform and fragile.
#
# source digest  A hash of exactly the files that go into the image, baked in at
#   (CHOSEN)     build time and read back OUT OF THE RUNNING CONTAINER. It
#                tracks content, so it moves on an uncommitted edit; it is
#                uniform across both workloads regardless of how the image
#                reached the node; and reading it from the running container's
#                filesystem makes the answer a fact about what is RUNNING rather
#                than about what was tagged, pushed or recorded.
#
# The repo already reached this conclusion once: build-sign-dashboard.sh has
# computed a `SOURCE_ID` tar-fingerprint since the dashboard supply-chain work,
# to stop BuildKit reusing application layers across source trees. This file
# promotes that computation to a shared definition and extends it to the runner.
#
# ─── Why the definition must live in exactly one place ──────────────────────
#
# The guard is only meaningful if the fingerprint it computes at CHECK time is
# produced by the same code as the fingerprint baked in at BUILD time. Two
# copies of the same tar pipeline drift the moment one is edited, and a guard
# that fires on an up-to-date deployment gets muted — which is strictly worse
# than no guard. scripts/check-backends.sh makes the same argument for reading
# nginx.conf rather than a hand-maintained backend list. So: build sites source
# this file, the guard sources this file, and no one recomputes it inline.
#
# ─── Why the runner's path set is derived from its Dockerfile ───────────────
#
# supercred-demo-runner builds from the REPO ROOT but COPYs a dozen specific
# paths. Fingerprinting the whole root would move the ID on every unrelated
# commit, the guard would cry wolf daily, and it would be muted within a week.
# Fingerprinting a hand-written list would silently develop blind spots the
# moment someone adds a COPY. So the list is read out of the Dockerfile — the
# same reasoning check-backends.sh applies to nginx.conf: parse the artifact
# that actually determines the answer, and it cannot drift from reality.

# shellcheck shell=bash

SOURCE_ID_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ID_REPO_ROOT="$(cd "${SOURCE_ID_LIB_DIR}/../.." && pwd)"

# The path inside every instrumented image that carries its build identity.
# Read with `cat` only — nothing here may require jq, python or a package
# manager to be present in the runtime image.
SOURCE_ID_MARKER_PATH="${SOURCE_ID_MARKER_PATH:-/etc/osramp-build-id}"

# workload -> build context, relative to the repo root.
source_id_context() {
	case "$1" in
	dashboard-signalloom) printf 'd2-signalloom/apps/dashboard-signalloom' ;;
	supercred-demo-runner) printf '.' ;;
	*) return 1 ;;
	esac
}

# workload -> Dockerfile, relative to the repo root.
source_id_dockerfile() {
	case "$1" in
	dashboard-signalloom) printf 'd2-signalloom/apps/dashboard-signalloom/Dockerfile' ;;
	supercred-demo-runner) printf 'd2-signalloom/apps/supercred-demo-runner/Dockerfile' ;;
	*) return 1 ;;
	esac
}

source_id_workloads() {
	printf 'dashboard-signalloom\nsupercred-demo-runner\n'
}

# Every context-relative path a Dockerfile COPYs in, plus the Dockerfile itself.
#
# `COPY --from=<stage>` is skipped: its source is another build stage, not the
# context, so it contributes nothing a context fingerprint could observe (the
# stage's own inputs are already covered by the COPY lines that feed it).
# The final token of a COPY is the destination and is dropped.
source_id_copied_paths() {
	local dockerfile="$1" dockerfile_rel="${2:-$1}"
	{
		awk '
			/^[[:space:]]*COPY[[:space:]]/ {
				if ($0 ~ /--from=/) next
				# Drop the COPY keyword and any remaining flags, then the destination.
				for (i = 2; i < NF; i++) {
					if ($i ~ /^--/) continue
					print $i
				}
			}
		' "$dockerfile"
		# A Dockerfile edit changes the image even when no COPYd file moved.
		# Emitted context-relative, like the COPY sources it sits alongside.
		printf '%s\n' "$dockerfile_rel"
	} | sort -u
}

# Deterministic content hash of a set of paths beneath a root.
#
# --sort=name, a fixed mtime and zeroed ownership are what make this stable
# across machines and checkouts; without them the same bytes hash differently on
# every clone and the guard is noise.
source_id_hash_paths() {
	local root="$1"
	shift
	# The excludes mirror the repo-root .dockerignore, and must keep mirroring it.
	# The runner COPYs the whole of fe-signalloom/src, so running the test suite
	# once leaves .coverage and a tree of .pyc files inside a hashed path. Without
	# these, the fingerprint changed every time anyone ran pytest, and two
	# checkouts of the SAME commit disagreed — measured at dda1d702 against
	# 95b668d2, differing in nothing but build artefacts. A guard that reports
	# drift against a matching deployment is a guard that gets ignored, which
	# costs more than not having one.
	tar \
		--sort=name \
		--mtime='UTC 1970-01-01' \
		--owner=0 \
		--group=0 \
		--numeric-owner \
		--exclude-vcs \
		--exclude='__pycache__' \
		--exclude='*.pyc' \
		--exclude='*.pyo' \
		--exclude='.pytest_cache' \
		--exclude='.coverage' \
		-cf - -C "$root" "$@" | sha256sum | awk '{print $1}'
}

# The fingerprint of a workload's build inputs as they are ON DISK RIGHT NOW.
#
# This is the "expected" side of the comparison. The value baked into an image
# is this same function evaluated at build time.
source_id_for() {
	local workload="$1"
	local root context dockerfile id
	root="${SOURCE_ID_REPO_ROOT}"

	context="$(source_id_context "$workload")" || {
		printf 'source-id: unknown workload: %s\n' "$workload" >&2
		return 2
	}
	dockerfile="$(source_id_dockerfile "$workload")"

	case "$workload" in
	dashboard-signalloom)
		# Kept byte-for-byte identical to the excludes in the context's
		# .dockerignore (.git, node_modules, dist, coverage). A fingerprint that
		# covers files the build never sees moves for no reason; one that misses
		# files the build does see is blind. Both make the guard useless.
		id="$(tar \
			--sort=name \
			--mtime='UTC 1970-01-01' \
			--owner=0 \
			--group=0 \
			--numeric-owner \
			--exclude-vcs \
			--exclude='./node_modules' \
			--exclude='./dist' \
			--exclude='./coverage' \
			-cf - -C "${root}/${context}" . | sha256sum | awk '{print $1}')"
		;;
	*)
		local paths=()
		while IFS= read -r p; do
			[ -n "$p" ] || continue
			[ -e "${root}/${p}" ] || {
				# A COPY naming a path that does not exist means the image cannot
				# build at all. Say so here rather than emitting a fingerprint over
				# a partial set, which would compare equal to nothing and read as
				# drift against a perfectly good deployment.
				printf 'source-id: %s COPYs %s, which does not exist\n' "$workload" "$p" >&2
				return 2
			}
			paths+=("$p")
		done < <(source_id_copied_paths "${root}/${dockerfile}" "${dockerfile}")
		[ "${#paths[@]}" -gt 0 ] || {
			printf 'source-id: no COPY sources found in %s\n' "$dockerfile" >&2
			return 2
		}
		id="$(source_id_hash_paths "${root}/${context}" "${paths[@]}")"
		;;
	esac

	[ -n "$id" ] || {
		printf 'source-id: fingerprint for %s is empty\n' "$workload" >&2
		return 2
	}
	printf '%s' "$id"
}

# Commit identity, for the human reading a failure — never for the comparison.
# `-dirty` is appended when the tree has uncommitted changes, which is precisely
# the state in which a git SHA alone would have lied.
source_id_git_ref() {
	local sha dirty=''
	sha="$(git -C "${SOURCE_ID_REPO_ROOT}" rev-parse --short HEAD 2>/dev/null)" || {
		printf 'unknown'
		return 0
	}
	git -C "${SOURCE_ID_REPO_ROOT}" diff --quiet HEAD 2>/dev/null || dirty='-dirty'
	printf '%s%s' "$sha" "$dirty"
}

# The --build-arg flags a build site must pass for its image to be checkable.
# Build sites call this rather than assembling the flags themselves, so an image
# can never be built with a fingerprint computed a different way.
source_id_build_args() {
	local workload="$1" id
	id="$(source_id_for "$workload")" || return 1
	printf -- '--build-arg\nSOURCE_ID=%s\n--build-arg\nGIT_REF=%s\n' "$id" "$(source_id_git_ref)"
}
