#!/usr/bin/env bats
#
# The registry-cache mapping table, which had no test at all until 2026-08-21.
#
# ─── What this defends, and why it is worth a suite of its own ──────────────
#
# scripts/registry-cache.sh:24 carried `https://docker.io` in the `server`
# field for four months. That URL is not a registry: it 302s to the Docker
# marketing site, which answers 200 text/html to ANY path, including
# /v2/<name>/manifests/<ref>.
#
# containerd derives a descriptor's mediaType from the response Content-Type.
# So the fallback did not fail — it SUCCEEDED, and wrote an HTML page in as the
# image record's target. Nothing complained at pull time. The damage surfaced
# minutes later and one subsystem away, as
#
#   unexpected media type text/html for sha256:fc4f0cf0...
#
# during CRI adoption, where it read as a corrupt local image. Three of four
# lanes aborted on it; the fourth escaped only because its kubelet pull loop
# happened to die after 80s instead of running for 19 minutes.
#
# The cost of finding it was hours. The defect is one field. That asymmetry is
# the whole argument for this file.
#
# ─── The invariant ──────────────────────────────────────────────────────────
#
# Field 2 (the URL the pull-through cache proxies to) and field 4 (the URL
# containerd falls back to) address the SAME upstream registry by two routes.
# They must therefore name the same host. Four of the five mappings already
# satisfied this; only `dockerio` did not, and it was the only one that broke.
#
# This is asserted STATICALLY and offline on purpose. A network probe would be
# the more direct test, but it would couple the suite to Docker Hub's
# availability and would not run in the offline gate — so it would be skipped
# exactly when it mattered.

setup() {
	repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	script="$repo/scripts/registry-cache.sh"
}

# Extract the mapping table as "name|remote|hostdir|server" lines, without
# sourcing the script (which would need docker and would run its side effects).
mappings() {
	sed -n '/^REGISTRY_CACHE_MAPPINGS=(/,/^)/p' "$script" \
		| grep -oE '"[^"]+\|[^"]+"' \
		| tr -d '"'
}

@test "RC the mapping table is readable and non-empty" {
	run mappings
	[ "$status" -eq 0 ]
	# A parser that silently returns nothing would make EVERY assertion below
	# pass vacuously. This is the anchor that makes the rest mean something.
	[ "${#lines[@]}" -ge 5 ]
}

@test "RC every mapping has exactly four fields" {
	while IFS= read -r m; do
		[ -n "$m" ] || continue
		n=$(awk -F'|' '{print NF}' <<<"$m")
		[ "$n" -eq 4 ] || {
			echo "mapping has $n fields, expected 4: $m" >&2
			return 1
		}
	done < <(mappings)
}

# THE REGRESSION TEST. This is the assertion that would have caught the defect.
@test "RC the server URL names the same host as the upstream remote URL" {
	while IFS= read -r m; do
		[ -n "$m" ] || continue
		remote=$(cut -d'|' -f2 <<<"$m")
		server=$(cut -d'|' -f4 <<<"$m")
		[ "$remote" = "$server" ] || {
			echo "mapping '$(cut -d'|' -f1 <<<"$m")' addresses two different hosts:" >&2
			echo "  upstream remote : $remote" >&2
			echo "  containerd server: $server" >&2
			echo "" >&2
			echo "These must be the same registry. A 'server' that is a vanity" >&2
			echo "domain rather than a registry API host returns 200 text/html," >&2
			echo "which containerd records as the image's mediaType and poisons" >&2
			echo "the image record. See this file's header." >&2
			return 1
		}
	done < <(mappings)
}

# Named explicitly, because this exact value cost hours and is the one a
# reasonable person would reintroduce — 'docker.io' reads as obviously correct.
@test "RC no mapping uses the docker.io vanity domain as a server" {
	run mappings
	[ "$status" -eq 0 ]
	! grep -qE '\|https://docker\.io$' <<<"$output" || {
		echo "https://docker.io is NOT a registry — it redirects to the Docker" >&2
		echo "marketing site, which answers 200 text/html to any path." >&2
		echo "Use https://registry-1.docker.io." >&2
		return 1
	}
}

# ─── POSITIVE CONTROLS ──────────────────────────────────────────────────────
#
# Without these, a mappings() that returned nothing — or returned lines this
# grep cannot match — would make every test above green forever. That is the
# precise failure shape this repo keeps rediscovering, so it is asserted rather
# than assumed.

@test "RC MUTATION the host-agreement check can SEE a mismatched mapping" {
	bad="dockerio|https://registry-1.docker.io|docker.io|https://docker.io"
	remote=$(cut -d'|' -f2 <<<"$bad")
	server=$(cut -d'|' -f4 <<<"$bad")
	# The comparison the real test performs must reject the historical value.
	[ "$remote" != "$server" ]
}

@test "RC MUTATION the vanity-domain grep can SEE the historical value" {
	bad="dockerio|https://registry-1.docker.io|docker.io|https://docker.io"
	grep -qE '\|https://docker\.io$' <<<"$bad"
}

@test "RC MUTATION the parser really reads THIS file, not a cached copy" {
	# Proves mappings() is coupled to the real script: a table that is not
	# there cannot be found.
	run mappings
	[ "$status" -eq 0 ]
	grep -q 'dockerio' <<<"$output"
	grep -q 'registry.k8s.io' <<<"$output"
}
