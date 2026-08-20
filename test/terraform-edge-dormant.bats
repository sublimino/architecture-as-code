#!/usr/bin/env bats
#
# "This estate instantiates no web edge" as a TESTED property, not as an
# accident of a comment block.
#
# ─── The fact being guarded ─────────────────────────────────────────────────
#
# There is no HTTPS load balancer anywhere in this project. Verified live
# against sl-port-over-sandbox on 2026-08-20: zero forwarding rules, zero
# backend services, zero global addresses, zero managed SSL certificates, zero
# Cloud Armor policies. The only reason is that `module "edge"` is commented
# out in terraform/environments/main.tf.
#
# That is a dangerous way for a security property to be true. A future edit
# that uncomments the block reintroduces a public HTTPS frontend with
# Identity-Aware Proxy in front of it, and before this file existed nothing in
# the suite would have gone red.
#
# ─── Why this is not a grep ─────────────────────────────────────────────────
#
# The obvious guard is `grep -q '# module "edge"' terraform/environments/main.tf`.
# It is worthless. It goes green the moment the literal moves to another file,
# gets reworded, gains a blank line, or has its label renamed — and it goes
# green for a tree where the module is live but written differently. This repo
# has already shipped guards that were satisfied by the comment explaining the
# rule rather than by the rule.
#
# So this file asks Terraform what the module graph ACTUALLY CONTAINS.
# `terraform get` resolves and records every module the configuration really
# instantiates. A commented-out block is not a module; an uncommented one is,
# whatever it is called. The evidence is the resolved graph, not the source
# text.
#
# ─── Why a scratch TF_DATA_DIR on every run, and why that is the whole point ─
#
# The checked-in terraform/environments/.terraform/modules/modules.json cannot
# be trusted. The repo's own `gcp_tf_init_offline` skips `terraform init`
# entirely when .terraform/providers already exists, so that file can be
# arbitrarily stale — it reflects whenever providers were last installed, not
# the current configuration. A guard reading it would report a clean estate
# while a live edge module sat in the config, and it would do so silently.
#
# Every graph here is therefore built fresh into a throwaway TF_DATA_DIR.
# `terraform get` touches neither providers nor the backend, and every module
# source in this root is a local relative path, so it is offline and instant.
#
# ─── Absence versus presence, which are guarded differently on purpose ──────
#
# The ABSENCE of the edge is proven by the module graph, above. The PRESENCE of
# the documented path back — modules/edge, its six test suites, WIRING.md step
# 4, and the commented block itself — is proven by grep, and that is correct.
# Andy's decision is that the load balancer returns eventually, so the re-enable
# path must not rot. Do not "simplify" the graph check into a grep to match
# them; they are answering opposite questions.
#
# Offline. No network, no credentials, no cloud.

setup() {
	repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	tf="$repo/terraform"
	root="$tf/environments"
	edge_mod="$tf/modules/edge"
	main_tf="$root/main.tf"
	wiring="$root/WIRING.md"
}

# Emit "<key>\t<source>\t<dir>" for every module the configuration at $1 really
# instantiates. Returns non-zero if `terraform get` fails or writes no graph —
# neither is a skip condition, because a guard that skips is a guard that is
# green for the wrong reason.
module_graph() {
	local root_dir="${1:-$root}"
	local scratch rc
	scratch="$(mktemp -d)"

	TF_DATA_DIR="$scratch" terraform -chdir="$root_dir" get >/dev/null 2>&1
	rc=$?

	if [ "$rc" -ne 0 ] || [ ! -f "$scratch/modules/modules.json" ]; then
		rm -rf "$scratch"
		return 1
	fi

	jq -r '.Modules[] | [.Key, .Source, .Dir] | @tsv' "$scratch/modules/modules.json"
	rc=$?
	rm -rf "$scratch"
	return "$rc"
}

# A self-contained copy of terraform/{environments,modules} so a test can mutate
# the configuration without touching the real tree. The relative `../modules/…`
# sources resolve inside the copy exactly as they do in the repo. Echoes the
# path of the copied ENVIRONMENTS root.
#
# ─── Why tar with an exclude rather than `cp -R` ────────────────────────────
#
# `.terraform/` holds the installed provider binaries: 240M under environments
# and 1.9G under modules, against 944K of actual HCL. A plain `cp -R` copies
# 2.1G per call, and BATS_TEST_TMPDIR lives on a tmpfs — the second such copy
# in one run filled /tmp, `cp` gave up part-way, and the result was an EMPTY
# configuration directory.
#
# That failure is worth spelling out because of how it presented: an empty
# config makes `terraform get` succeed, report no modules, and satisfy "no edge
# module is instantiated" perfectly. A disk-space accident silently became a
# passing security assertion. Hence both the exclude and the completeness check
# below; a copy that did not arrive intact must abort the test, never quietly
# become evidence.
copy_root() {
	local dest="$1"
	mkdir -p "$dest"

	tar -c --exclude='.terraform' --exclude='.terraform.lock.hcl' \
		-C "$tf/.." terraform/environments terraform/modules | tar -x -C "$dest" || return 1

	# The copy is the thing under test in every caller. If it did not arrive,
	# fail here rather than letting an empty tree answer a question about the
	# real one.
	[ -f "$dest/terraform/environments/main.tf" ] || return 1
	[ -d "$dest/terraform/modules/edge" ] || return 1
	[ -d "$dest/terraform/modules/network" ] || return 1

	printf '%s\n' "$dest/terraform/environments"
}

# Strip the leading "# " from the commented `module "edge"` block, making it a
# real module. This is the exact edit the guard exists to catch.
uncomment_edge_block() {
	perl -0pi -e 's/^# module "edge" \{\n(.*?)^# \}$/my $b=$1; $b =~ s{^# ?}{}gm; "module \"edge\" {\n$b}"/sme' "$1"
}

# ─── The positive control ───────────────────────────────────────────────────
#
# FIRST, because every absence assertion below is vacuously true against an
# empty, missing or unparseable graph. If this test is red, the two that follow
# prove nothing whatsoever regardless of their colour.

@test "the module graph is readable and names the modules this root really instantiates" {
	run module_graph
	[ "$status" -eq 0 ]
	[ -n "$output" ]

	# These three are live, uncommented module blocks in main.tf today. If the
	# graph cannot see them it is not seeing the configuration, and the absence
	# assertions below are measuring nothing.
	for src in ../modules/env-contract ../modules/network ../modules/compute; do
		printf '%s\n' "$output" | grep -qF "	${src}	" || {
			echo "the module graph does not contain ${src}." >&2
			echo "Every 'no edge is instantiated' assertion in this file is" >&2
			echo "vacuous until this passes. Graph was:" >&2
			printf '%s\n' "$output" >&2
			return 1
		}
	done
}

@test "the environments root instantiates no edge module" {
	run module_graph
	[ "$status" -eq 0 ]
	[ -n "$output" ]

	# Matched on the module SOURCE path, not on the block label. Renaming
	# `module "edge"` to `module "frontend"` changes the key and changes
	# nothing else: the source is still ../modules/edge and this still fires.
	local offenders
	offenders="$(printf '%s\n' "$output" | grep -E '(^|	)[^	]*modules/edge($|	|/)' || true)"

	[ -z "$offenders" ] || {
		echo "the environments root instantiates an edge module:" >&2
		printf '%s\n' "$offenders" >&2
		echo >&2
		echo "modules/edge is the HTTPS load balancer: a global forwarding rule," >&2
		echo "a managed certificate, a backend service with Identity-Aware Proxy," >&2
		echo "and a Cloud Armor policy. There is no such resource in this GCP" >&2
		echo "project today and Andy's decision is that there should not be one" >&2
		echo "yet. If you are re-enabling it deliberately, this guard and" >&2
		echo "terraform/environments/tests/edge_dormant.tftest.hcl are the two" >&2
		echo "places that must change with it — see the comment above" >&2
		echo "local.edge_environments in terraform/environments/main.tf." >&2
		return 1
	}
}

# ─── Anti-vacuity: the guard is proven to fire, inside the suite ────────────
#
# A guard that has never been observed failing is decoration. These two tests
# falsify it on a throwaway copy, so the proof travels with the guard rather
# than living only in test/edge-dormant-mutation-proof.sh.

@test "uncommenting the edge module block makes the graph guard fire" {
	local tmp env_root
	tmp="$BATS_TEST_TMPDIR/uncommented"
	env_root="$(copy_root "$tmp")"

	uncomment_edge_block "$env_root/main.tf"
	grep -q '^module "edge" {' "$env_root/main.tf" || {
		echo "the mutation did not uncomment the block, so this test would" >&2
		echo "have passed without ever exercising the guard. The block's shape" >&2
		echo "in main.tf has changed; fix uncomment_edge_block." >&2
		return 1
	}

	run module_graph "$env_root"
	[ "$status" -eq 0 ]
	printf '%s\n' "$output" | grep -qE '(^|	)[^	]*modules/edge($|	|/)' || {
		echo "the edge module was uncommented and the graph did not report it." >&2
		echo "The guard above cannot detect the thing it exists to detect." >&2
		printf '%s\n' "$output" >&2
		return 1
	}
}

@test "a stale .terraform modules.json naming an edge module does not fool the guard" {
	local tmp env_root
	tmp="$BATS_TEST_TMPDIR/poisoned"
	env_root="$(copy_root "$tmp")"

	# Exactly the failure a guard reading the checked-in .terraform would hit,
	# but inverted so it is detectable: the on-disk cache claims an edge module
	# that the configuration does not instantiate. A fresh `terraform get`
	# overwrites this; a stale read would report it.
	mkdir -p "$env_root/.terraform/modules"
	cat >"$env_root/.terraform/modules/modules.json" <<-'JSON'
		{"Modules":[{"Key":"","Source":"","Dir":"."},{"Key":"edge","Source":"../modules/edge","Dir":"../modules/edge"}]}
	JSON

	run module_graph "$env_root"
	[ "$status" -eq 0 ]
	# `if`, not `cmd && { … }`. Under bats' errexit a trailing `&&` whose left
	# side fails is itself a failing statement, so the safe case would fail the
	# test. This repo has shipped several guards broken in exactly that way.
	if printf '%s\n' "$output" | grep -qE '(^|	)[^	]*modules/edge($|	|/)'; then
		echo "the guard read a stale .terraform/modules/modules.json instead of" >&2
		echo "rebuilding the graph. Every verdict it gives is then a verdict" >&2
		echo "about whenever providers were last installed, not about the" >&2
		echo "configuration in front of it." >&2
		return 1
	fi

	# And the fresh graph is a real one, not an empty one that happens to omit
	# the edge.
	printf '%s\n' "$output" | grep -qF "	../modules/network	"
}

# ─── The re-enable path must not rot ────────────────────────────────────────
#
# Andy wants the load balancer eventually. modules/edge stays, with its six
# passing tftest suites, as the future LB. These guard the path back.

@test "the edge module and its six test suites still exist" {
	[ -d "$edge_mod" ] || {
		echo "terraform/modules/edge/ is gone. It is dormant, not deleted:" >&2
		echo "it is the documented path back to an HTTPS load balancer." >&2
		return 1
	}

	local suites
	suites="$(find "$edge_mod/tests" -maxdepth 1 -name '*.tftest.hcl' | wc -l)"
	[ "$suites" -eq 6 ] || {
		echo "expected 6 .tftest.hcl suites under modules/edge/tests, found ${suites}." >&2
		echo "The edge is dormant, so nothing exercises it in the estate; its" >&2
		echo "own test suites are the only thing keeping it correct until it" >&2
		echo "is wired back up." >&2
		return 1
	}
}

@test "the commented module edge block and WIRING step 4 still document the way back" {
	grep -q '^# module "edge" {' "$main_tf" || {
		echo "the commented 'module \"edge\"' block is gone from main.tf." >&2
		echo "Deleting it removes the re-enable path; the block is deliberately" >&2
		echo "kept, and its absence is not the same as the edge being dormant." >&2
		return 1
	}

	grep -q 'module "edge"' "$wiring" || {
		echo "WIRING.md no longer mentions module \"edge\" (step 4)." >&2
		return 1
	}

	# The block must still name the module source, or "the way back" is a
	# comment that no longer says where to go.
	grep -q '^#   source   = "\.\./modules/edge"' "$main_tf" || {
		echo "the commented edge block no longer names ../modules/edge." >&2
		return 1
	}
}
