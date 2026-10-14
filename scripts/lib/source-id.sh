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
	docs-signalloom) printf 'd2-signalloom/apps/docs-signalloom' ;;
	fe-signalloom) printf 'd2-signalloom/apps/fe-signalloom' ;;
	supercred-demo-runner) printf '.' ;;
	*) return 1 ;;
	esac
}

# workload -> Dockerfile, relative to the repo root.
source_id_dockerfile() {
	case "$1" in
	dashboard-signalloom) printf 'd2-signalloom/apps/dashboard-signalloom/Dockerfile' ;;
	docs-signalloom) printf 'd2-signalloom/apps/docs-signalloom/Dockerfile' ;;
	fe-signalloom) printf 'd2-signalloom/apps/fe-signalloom/Dockerfile' ;;
	supercred-demo-runner) printf 'd2-signalloom/apps/supercred-demo-runner/Dockerfile' ;;
	*) return 1 ;;
	esac
}

source_id_workloads() {
	printf 'dashboard-signalloom\ndocs-signalloom\nfe-signalloom\nsupercred-demo-runner\n'
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

# Deterministic content hash of the TRACKED files under a set of paths.
#
# The set is `git ls-files` (the index), each hashed with its content on disk:
# an uncommitted edit to a tracked file still moves the fingerprint, but an
# untracked or ignored file cannot. Until 2026-10-03 this tarred the
# directories on disk, so a gitignored build artefact
# (apps/stun-sentinel/bpf/sentinel_probe.o, left by bpf/build.sh) moved the
# sentinel tag in one checkout and not in another of the same commit -- and
# what counts as "ignored" depends on each machine's global excludes (*.o is
# ignored on the dev box only by ~/.gitignore_global). The index is the same
# everywhere. Untracked and ignored files are the dirty guard's business
# (source_id_dirty_inputs), which refuses them.
#
# --mtime, --owner/--group and --numeric-owner keep the archive independent of
# the checkout; --mode normalises permissions to what git records (the
# executable bit, nothing else), since the rest is the umask of whoever wrote
# the file -- 664 from a checkout under umask 0002, 644 from the bpf2go
# container -- and split one commit's sentinel tag in two (2026-10-03); the list is sorted bytewise and given with --no-recursion, so
# the archive holds exactly these files in exactly this order.
source_id_hash_paths() {
	local root="$1"
	shift
	source_id_hash_files "$root" '' "$@"
}

# source_id_hash_files ROOT EXCLUDE_ERE PATH...: source_id_hash_paths with the
# root-relative paths matching EXCLUDE_ERE left out ('' excludes nothing).
# For tracked files a context's .dockerignore keeps out of the build (the docs
# site's generated .astro/ is tracked and rewritten by every dev run).
#
# SOURCE_ID_INCLUDE_UNTRACKED=1 adds untracked files that are NOT ignored
# (`git ls-files --others --exclude-standard`). The deployed-staleness
# fingerprints (source_id_for) use it: their builds have no dirty guard, a new
# source file is in the image the moment it exists, and the check must see
# it. The src- tags (sentinel) do not: their guard refuses untracked files, so
# the tag stays exactly the committed source. Ignored files are never hashed.
#
# Fails, printing nothing, outside a git repository or when no file remains:
# a hash of the empty set would match nothing and read as drift.
source_id_hash_files() {
	local root="$1" exclude="$2"
	shift 2
	local listed kept
	listed="$(mktemp "${TMPDIR:-/tmp}/source-id.XXXXXX")" || return 2
	kept="$(mktemp "${TMPDIR:-/tmp}/source-id.XXXXXX")" || {
		rm -f "$listed"
		return 2
	}
	local sets=(--cached)
	[ "${SOURCE_ID_INCLUDE_UNTRACKED:-}" = 1 ] && sets+=(--others --exclude-standard)
	if ! git -C "$root" ls-files -z "${sets[@]}" -- "$@" >"$listed"; then
		printf 'source-id: git ls-files failed under %s\n' "$root" >&2
		rm -f "$listed" "$kept"
		return 2
	fi
	local f
	while IFS= read -r -d '' f; do
		# A tracked file deleted on disk is absent from the archive, so its
		# deletion moves the fingerprint like any other edit.
		[ -e "${root}/${f}" ] || [ -L "${root}/${f}" ] || continue
		if [ -n "$exclude" ] && [[ "$f" =~ $exclude ]]; then
			continue
		fi
		printf '%s\0' "$f"
	done <"$listed" | LC_ALL=C sort -z >"$kept"
	if [ ! -s "$kept" ]; then
		printf 'source-id: no tracked files under %s in %s\n' "$*" "$root" >&2
		rm -f "$listed" "$kept"
		return 2
	fi
	# pipefail: tar warns, exits non-zero and still emits a partial archive
	# for a file it cannot read, and without it that partial archive was
	# hashed into a plausible, wrong fingerprint.
	local id
	id="$(set -o pipefail; tar \
		--mtime='UTC 1970-01-01' \
		--owner=0 \
		--group=0 \
		--numeric-owner \
		--mode='u=rwX,go=rX' \
		--no-recursion \
		-C "$root" --null -T "$kept" \
		-cf - | sha256sum | awk '{print $1}')" || {
		printf 'source-id: tar failed under %s\n' "$root" >&2
		rm -f "$listed" "$kept"
		return 2
	}
	rm -f "$listed" "$kept"
	[ -n "$id" ] || return 2
	printf '%s\n' "$id"
}

# source_id_dirty_inputs ROOT PATH...: every input that is not exactly the
# committed source -- modified, untracked AND ignored -- as `git status
# --porcelain` lines; empty when clean. The tag guards refuse on any output.
# Ignored files matter because they are in the docker build context: a COPY of
# a directory ships them, under a tag whose fingerprint (tracked files only)
# never saw them. Fails closed when git cannot answer.
source_id_dirty_inputs() {
	local root="$1"
	shift
	git -C "$root" status --porcelain --untracked-files=all --ignored=matching -- "$@"
}

# source_id_src_tag LABEL CONTEXT DOCKERFILE_REL [DIRTY_CHECK]: the immutable
# `src-<12 hex>` image tag for a workload whose build inputs are exactly the
# paths its Dockerfile COPYs, printed on stdout.
#
#   LABEL           prefix for every diagnostic, e.g. "policy-engine-image-tag"
#   CONTEXT         docker build context, relative to the repo root
#   DOCKERFILE_REL  the Dockerfile, relative to CONTEXT
#   DIRTY_CHECK     1 (default) refuses when any input is not the committed
#                   source; 0 prints the fingerprint regardless
#
# ─── Why this is here and not copied per workload ───────────────────────────
#
# scripts/sentinel-image-tag.sh and scripts/policy-engine-image-tag.sh need the
# same seven steps in the same order: resolve the context, refuse a dirty input
# set, read the COPY sources out of the Dockerfile, refuse a COPY of a path that
# does not exist, refuse an empty fingerprint, hash, truncate to 12. A per
# workload copy of that is a per workload place to forget a defence — and the
# defences are the whole point: the dirty guard, the missing-COPY refusal and the
# empty-hash refusal were each added after a specific failure, and a sibling
# script written by copy-paste a month later would carry whichever subset the
# author happened to notice. This file's own header already makes the argument
# for the fingerprint itself ("the definition must live in exactly one place");
# the procedure that wraps it has the same property.
#
# The named per-workload scripts remain, as four-line wrappers. They are not
# ceremony: a recipe line containing $(MAKE) is executed by GNU make even under
# -n, so the Makefiles must call a plain script rather than a sub-make target
# (see the header of scripts/sentinel-image-tag.sh for what that cost).
source_id_src_tag() {
	local label="$1" context="$2" dockerfile_rel="$3" dirty_check="${4:-1}"
	local root="${SOURCE_ID_REPO_ROOT}"
	cd "${root}/${context}" || {
		printf '%s: no such build context: %s\n' "$label" "$context" >&2
		return 2
	}
	if [ "$dirty_check" -eq 1 ]; then
		local dirty
		# The inputs are the COPY sources plus the Dockerfile; refusing on the
		# whole context would refuse on files the image never sees.
		local -a inputs=()
		local p
		while IFS= read -r p; do
			[ -n "$p" ] || continue
			inputs+=("$p")
		done < <(source_id_copied_paths "$dockerfile_rel" "$dockerfile_rel")
		dirty=$(source_id_dirty_inputs . "${inputs[@]}") || {
			printf '%s: git status failed; refusing\n' "$label" >&2
			return 2
		}
		if [ -n "$dirty" ]; then
			printf '%s: refusing a -dirty build; inputs that are not the committed source (modified, untracked or ignored -- an ignored file still enters the docker build context):\n' "$label" >&2
			printf '%s\n' "$dirty" >&2
			return 1
		fi
	fi
	local -a paths
	mapfile -t paths < <(source_id_copied_paths "$dockerfile_rel" "$dockerfile_rel")
	[ "${#paths[@]}" -gt 0 ] || {
		printf '%s: no COPY sources in %s\n' "$label" "$dockerfile_rel" >&2
		return 2
	}
	local q
	for q in "${paths[@]}"; do
		[ -e "$q" ] || {
			printf '%s: the Dockerfile COPYs %s, which does not exist\n' "$label" "$q" >&2
			return 2
		}
	done
	local id
	id=$(source_id_hash_paths . "${paths[@]}") && [ -n "$id" ] || {
		printf '%s: empty fingerprint\n' "$label" >&2
		return 2
	}
	printf 'src-%s\n' "${id:0:12}"
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
		# Tracked files only (source_id_hash_files); the excludes mirror the
		# context's .dockerignore (.git, node_modules, dist, coverage) so a
		# tracked file the build never sees cannot move the fingerprint.
		id="$(SOURCE_ID_INCLUDE_UNTRACKED=1 source_id_hash_files "${root}/${context}" '^(node_modules|dist|coverage)/' .)"
		;;
	docs-signalloom)
		# As above; .astro/ is TRACKED here and rewritten by every dev run, and
		# its .dockerignore keeps it out of the build, so it is excluded too.
		id="$(SOURCE_ID_INCLUDE_UNTRACKED=1 source_id_hash_files "${root}/${context}" '^((node_modules|dist|dist-dev-docs|\.astro|test-results|playwright-report)/|dev-docs/\.astro/)' .)"
		;;
	fe-signalloom)
		# The whole build context, not a COPY-derived path list.
		#
		# The generic branch below resolves each COPY source against the REPO
		# ROOT, which is only correct when the context IS the repo root (it is,
		# for supercred-demo-runner). fe-signalloom builds from
		# d2-signalloom/apps/fe-signalloom and COPYs `src/requirements.txt` and
		# `src/`, so that branch would look for ${root}/src, not find it, and
		# return 2 — reporting "cannot verify" forever on a workload that builds
		# perfectly. Hashing the context wholesale is both correct and a
		# superset of what the COPY lines name.
		#
		# Via source_id_hash_paths, tracked plus untracked-not-ignored: the
		# __pycache__, .pyc and .coverage that pytest leaves in src/ are ignored and cannot
		# move the fingerprint -- the guard reporting drift against a matching
		# deployment, which cost it its credibility once, cannot recur.
		#
		# There is no .dockerignore in this context, so those artefacts DO
		# enter the build context and the image; they are not source.
		id="$(SOURCE_ID_INCLUDE_UNTRACKED=1 source_id_hash_paths "${root}/${context}" .)"
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
		id="$(SOURCE_ID_INCLUDE_UNTRACKED=1 source_id_hash_paths "${root}/${context}" "${paths[@]}")"
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
