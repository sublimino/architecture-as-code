#!/usr/bin/env bats
#
# SLDC-P6-PRE: the teardown/cold-start preflight must pass only on a host where
# every check holds, and each check must fail on its own. Hermetic: a synthetic
# repo root, stub docker/kind/df/ip on a PATH that contains no real cluster
# tool, a fake cgroup root, and a bundle signed with an ephemeral key.
#
# @target scripts/verify-teardown-prereqs.sh scripts/lib/cluster-reset-helpers.sh
# @doc    docs/eap/SLDC-P6-PREFLIGHT.md

bats_require_minimum_version 1.5.0

setup() {
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	script="$root/scripts/verify-teardown-prereqs.sh"
	helpers="$root/scripts/lib/cluster-reset-helpers.sh"
	t="$BATS_TEST_TMPDIR"

	# PATH: stubs first, then symlinks to the plain tools the scripts need. No
	# real docker/kind/ip/kubectl is reachable.
	stub="$t/stub" tools="$t/tools"
	mkdir -p "$stub" "$tools"
	for b in bash sh env jq git awk grep sed sort uniq cut wc head tail cat cp mv rm mkdir mktemp \
		dirname basename date find stat tr openssl sha256sum tar gzip ls chmod timeout id hostname uname readlink xargs touch tee ln seq sleep cmp; do
		p="$(command -v "$b")" && ln -s "$p" "$tools/$b"
	done
	export PATH="$stub:$tools" STUB_LOG="$t/calls.log"
	: >"$STUB_LOG"
	mkstub docker 'case "$*" in info*) [ "${DOCKER_DOWN:-0}" = 1 ] && exit 1; exit 0 ;; "version --format"*) echo 27.0.0 ;; esac'
	mkstub kind 'echo "kind v0.32.0 go1.22 linux/amd64"'
	mkstub df 'echo "Filesystem 1K-blocks Used Available Use% Mounted"; echo "fake 999999999 1 ${DF_AVAIL_KB:-99999999} 1% /"'

	# Synthetic repo: catalog whose manifests exist, keys, a verified bundle.
	repo="$t/repo"
	mkdir -p "$repo/test/fixtures" "$repo/.evidence" "$repo/manifests"
	printf 'component\tkind\tmanifest_path\timage\trequired\n' >"$repo/test/fixtures/cold-start-manifests.tsv"
	for c in zot kusari; do
		echo "kind: Deployment" >"$repo/manifests/$c.yaml"
		printf '%s\tDeployment\tmanifests/%s.yaml\timg/%s:1\ttrue\n' "$c" "$c" "$c" >>"$repo/test/fixtures/cold-start-manifests.tsv"
	done
	export KEYS_DIR="$t/keys"
	mkdir -p "$KEYS_DIR"
	openssl genpkey -algorithm ed25519 -out "$KEYS_DIR/witness.pem" 2>/dev/null
	openssl pkey -in "$KEYS_DIR/witness.pem" -pubout -out "$KEYS_DIR/witness-pub.pem"
	touch "$KEYS_DIR/cosign.key" "$KEYS_DIR/cosign.pub"
	mkdir -p "$t/ev" && cp "$root"/test/fixtures/eap-evidence/* "$t/ev/"
	EAP_SIGNING_KEY="$KEYS_DIR/witness.pem" EAP_OPERATOR=bats EAP_CONTAINER_RUNTIME=x SOURCE_DATE_EPOCH=1790726400 \
		bash "$root/scripts/package-eap-evidence.sh" --quiet --out "$repo/.evidence" "$t/ev" >/dev/null 2>&1
	cp "$t/ev/audit-signature.sha256" "$repo/.evidence/"

	export CGROUP_ROOT="$t/cgroup"
	mkdir -p "$CGROUP_ROOT" && echo "cpu memory" >"$CGROUP_ROOT/cgroup.controllers"
	export REPO_ROOT="$repo"
	report="$t/readiness.json"
}

mkstub() { printf '#!/usr/bin/env bash\necho "%s $*" >>"$STUB_LOG"\n%s\n' "$1" "$2" >"$stub/$1"; chmod +x "$stub/$1"; }

preflight() { run --separate-stderr bash "$script" --dry-run --out "$report"; }

fails_only() { # CHECK-NAME: exit 1, exactly one failed check, and it is this one
	preflight
	[ "$status" -eq 1 ]
	[ "$(jq -r '"\(.verdict) \(.failed_checks)"' "$report")" = "FAIL 1" ]
	[[ "$stderr" == *"FAIL $1"* ]]
	[ "$(grep -c '^FAIL' <<<"$stderr")" -eq 1 ]
}

@test "no real cluster tool is reachable from the test PATH" {
	for b in docker kind df; do [ "$(command -v "$b")" = "$stub/$b" ]; done
	for b in kubectl ip iptables pkill make; do run ! command -v "$b"; done
}

@test "every check holds: exit 0, PASS 8/8, report written, repo untouched" {
	before="$(git -C "$root" status --porcelain)"
	preflight
	[ "$status" -eq 0 ]
	[[ "$output" == *"VERDICT: PASS (8/8 passed)"* ]]
	[ "$(jq -r '"\(.verdict) \(.total_checks) \(.failed_checks) \(.dry_run)"' "$report")" = "PASS 8 0 true" ]
	[ -s "$repo/ci-evidence/phase6-preflight-readiness.json" ]
	[ "$(git -C "$root" status --porcelain)" = "$before" ]
}

@test "docker daemon unreachable fails only the docker check" {
	export DOCKER_DOWN=1
	fails_only "Docker daemon socket accessible"
}

@test "kind missing fails only the kind check" {
	rm "$stub/kind"
	fails_only "Kind CLI available"
}

@test "cgroup v1 host fails only the cgroup check" {
	rm "$CGROUP_ROOT/cgroup.controllers"
	fails_only "cgroup v2 hierarchy active"
}

@test "a missing signing key fails only the keys check" {
	rm "$KEYS_DIR/cosign.pub"
	fails_only "Cryptographic signing keys intact"
}

@test "less than 5 GB free fails only the disk check" {
	export DF_AVAIL_KB=1024
	fails_only "Disk space adequate"
}

@test "a missing Phase 5 bundle fails only the bundle check" {
	rm "$repo/.evidence/eap-kusari-containment.tar.gz"
	fails_only "Phase 5 forensic evidence bundle preserved"
}

@test "a tampered Phase 5 bundle is not 'preserved'" {
	echo junk >>"$repo/.evidence/eap-kusari-containment.tar.gz"
	fails_only "Phase 5 forensic evidence bundle preserved"
}

@test "a missing catalog fails only the catalog check" {
	rm "$repo/test/fixtures/cold-start-manifests.tsv"
	fails_only "Cold-start manifest catalog ready"
}

@test "a catalog row naming a manifest that does not exist fails the catalog check" {
	rm "$repo/manifests/kusari.yaml"
	fails_only "Cold-start manifest catalog ready"
	[[ "$stderr" == *"manifests/kusari.yaml"* ]]
}

@test "an --out without a path is a usage error (exit 2)" {
	run bash "$script" --out
	[ "$status" -eq 2 ]
}

@test "committed catalog: every manifest_path exists in the repository" {
	missing=""
	while IFS=$'\t' read -r c _ p _ _; do
		[ -e "$root/$p" ] || missing="$missing $c:$p"
	done < <(tail -n +2 "$root/test/fixtures/cold-start-manifests.tsv")
	echo "missing:$missing" >&3
	[ -z "$missing" ]
}

@test "committed catalog: each manifest declares the catalogued kind, and workloads pin the catalogued image" {
	wrong=""
	while IFS=$'\t' read -r c k p img _; do
		grep -qE "^kind: ${k}\$" "$root/$p" || wrong="$wrong $c:kind=$k"
		case "$k" in
		HelmRelease | ResourceSet) ;;
		*) grep -qF "image: ${img}" "$root/$p" || wrong="$wrong $c:image=$img" ;;
		esac
	done < <(tail -n +2 "$root/test/fixtures/cold-start-manifests.tsv")
	echo "wrong:$wrong" >&3
	[ -z "$wrong" ]
}

# --- cluster-reset-helpers ----------------------------------------------------------

ip_links='13: veth664d764@if2: <UP> mtu 1500 master br-f7f9 state UP mode DEFAULT
14: vethorph01@if7: <UP> mtu 1500 state DOWN mode DEFAULT
15: veth9e2282f@if2: <UP> mtu 1500 master docker0 state UP mode DEFAULT'

@test "find_orphaned_veths lists only veths attached to no bridge" {
	mkstub ip "printf '%s\n' '$ip_links'"
	source "$helpers"
	run find_orphaned_veths
	[ "$status" -eq 0 ]
	[ "$output" = "vethorph01" ]
}

@test "cleanup_orphaned_veths never deletes a bridge-attached veth; dry run deletes nothing" {
	mkstub ip "case \"\$*\" in *'link show'*) printf '%s\n' '$ip_links' ;; esac"
	source "$helpers"
	run cleanup_orphaned_veths 1
	[ "$output" = "DRY-RUN: would remove orphaned veth vethorph01" ]
	run ! grep -q 'link delete' "$STUB_LOG"
	run cleanup_orphaned_veths 0
	[ "$(grep 'link delete' "$STUB_LOG")" = "ip link delete vethorph01" ]
}

@test "check_cgroup_v2_status: controllers file wins; docker CgroupVersion 2 is the fallback" {
	source "$helpers"
	run check_cgroup_v2_status
	[ "$status" -eq 0 ]
	rm "$CGROUP_ROOT/cgroup.controllers"
	mkstub docker 'echo 1'
	run check_cgroup_v2_status
	[ "$status" -eq 1 ]
	mkstub docker 'echo 2'
	run check_cgroup_v2_status
	[ "$status" -eq 0 ]
}
