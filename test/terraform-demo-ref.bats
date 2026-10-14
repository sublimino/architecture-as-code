#!/usr/bin/env bats
#
# GCP demo lane: source ref pinning (GCP_TF_DEMO_REF).
#
# Named `terraform-*.bats` so `make gcp-tf-validate` registers and runs it
# automatically via $(wildcard test/terraform-*.bats).

setup_file() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export REPO_ROOT
	export MAKEFILE="${REPO_ROOT}/Makefile"
	export DRIVER_SRC="${REPO_ROOT}/scripts/gcp-tf/demo-up.sh"
	export STUB_SRC="${REPO_ROOT}/test/fixtures/gcp-tf-demo/stub-gcloud"
	export DEX_STUB_SRC="${REPO_ROOT}/test/fixtures/gcp-tf-tailscale/stub-dex-origin"
}

setup() {
	[ -f "${MAKEFILE}" ]
	[ -f "${DRIVER_SRC}" ]
	[ -x "${DRIVER_SRC}" ]
	[ -f "${STUB_SRC}" ]
	[ -f "${DEX_STUB_SRC}" ]

	ENV_KEY="demo-7"
	root="${BATS_TEST_TMPDIR}/repo"
	stubdir="${BATS_TEST_TMPDIR}/bin"
	log="${BATS_TEST_TMPDIR}/gcloud.log"
	dexlog="${BATS_TEST_TMPDIR}/dex.log"
	surfaces="${BATS_TEST_TMPDIR}/surfaces"
	driver="${root}/scripts/gcp-tf/demo-up.sh"

	mkdir -p "${stubdir}" "${surfaces}"
	cp "${STUB_SRC}" "${stubdir}/gcloud"
	chmod +x "${stubdir}/gcloud"
	cp "${DEX_STUB_SRC}" "${stubdir}/dex-origin"
	chmod +x "${stubdir}/dex-origin"
	: >"${log}"
	: >"${dexlog}"

	make_repo
	write_handoff

	export PATH="${stubdir}:${PATH}"
	export STUB_GCLOUD_LOG="${log}"
	export STUB_DEX_LOG="${dexlog}"
	export GCP_TF_DEMO_DEX_ORIGIN_CMD="${stubdir}/dex-origin"
	export GCP_TF_DEMO_REPO_ROOT="${root}"
	export GCP_TF_DEMO_ENV="${ENV_KEY}"
	export GCP_TF_HANDOFF_DIR="${root}/deploy/gcp"
	export GCP_TF_DEMO_REPORT_DIR="${root}/demo-reports"
	export GCP_TF_DEMO_SURFACE_DIR="${surfaces}"
	export GCP_TF_DEMO_SSH_WAIT_ATTEMPTS=2
	export GCP_TF_DEMO_SSH_WAIT_INTERVAL=0
	export GCP_TF_DEMO_TIMEOUT_MINUTES=1
	export AFM_REQUIRED=0

	export STUB_VM_FS="${BATS_TEST_TMPDIR}/vmfs"
	mkdir -p "${STUB_VM_FS}"

	printf '#!/usr/bin/env bash\nexit 0\n' >"${stubdir}/probe-ok"
	chmod +x "${stubdir}/probe-ok"
	export GCP_TF_DEMO_PORT_PROBE="${stubdir}/probe-ok"
	export GCP_TF_DEMO_TUNNEL_WAIT_SECONDS=2
	export STUB_TUNNEL_HOLD=1

	printf '#!/usr/bin/env bash\nexit 1\n' >"${stubdir}/port-free"
	chmod +x "${stubdir}/port-free"
	export GCP_TF_DEMO_PREFLIGHT_PORT_PROBE="${stubdir}/port-free"
}

make_repo() {
	mkdir -p "${root}/scripts/gcp-tf" "${root}/scripts/lib" "${root}/deploy/gcp" "${root}/.keys" \
		"${root}/node_modules/left-pad" "${root}/terraform/environments/.terraform-demo-7" \
		"${root}/d2-signalloom"

	cp "${DRIVER_SRC}" "${driver}"
	chmod +x "${driver}"
	cp "${REPO_ROOT}/scripts/lib/wait.sh" "${root}/scripts/lib/wait.sh"

	printf '#!/usr/bin/env bash\necho "demo-pipeline ran"\n' >"${root}/scripts/gcp-tf/demo-pipeline.sh"
	chmod +x "${root}/scripts/gcp-tf/demo-pipeline.sh"

	printf 'COSIGN PRIVATE KEY MATERIAL\n' >"${root}/.keys/cosign.key"
	printf 'project_id = "acme-real-project-42"\n' >"${root}/deploy/gcp/environments.tfvars"
	printf 'deployer@acme-real-project-42.iam.gserviceaccount.com\n' >"${root}/deploy/gcp/deploy-sa"
	printf 'module.exports = 1\n' >"${root}/node_modules/left-pad/index.js"
	printf 'cached provider\n' >"${root}/terraform/environments/.terraform-demo-7/lock"
	printf 'all: ; @true\n' >"${root}/Makefile"
	printf 'the app v1\n' >"${root}/d2-signalloom/app.ts"

	cat >"${root}/.gitignore" <<'IGNORE'
.keys/
node_modules/
.terraform*
*.tfvars
*.handoff.json
deploy/gcp/deploy-sa
demo-reports*/
demo-surfaces*/
IGNORE

	git -C "${root}" init -q
	git -C "${root}" add -A
	git -C "${root}" -c user.name=t -c user.email=t@t \
		commit -q -m "fixture commit 1" --no-gpg-sign
	COMMIT_1_SHA="$(git -C "${root}" rev-parse HEAD)"
	COMMIT_1_SHORT="$(git -C "${root}" rev-parse --short HEAD)"

	# Add a second commit so we have a distinct ref to test
	printf 'the app v2\n' >"${root}/d2-signalloom/app.ts"
	git -C "${root}" add -A
	git -C "${root}" -c user.name=t -c user.email=t@t \
		commit -q -m "fixture commit 2" --no-gpg-sign
	COMMIT_2_SHA="$(git -C "${root}" rev-parse HEAD)"
	COMMIT_2_SHORT="$(git -C "${root}" rev-parse --short HEAD)"

	git -C "${root}" branch v1-branch "${COMMIT_1_SHA}"
}

write_handoff() {
	local port="${1:-8080}" op="${2-sl-operator@acme-real-project-42.iam.gserviceaccount.com}"
	jq -n \
		--arg env "${ENV_KEY}" \
		--argjson port "${port}" \
		--arg op "${op}" \
		'{schema: "signalloom.gcp.handoff/v1", schema_version: 1,
		  project_id: "acme-real-project-42", environment_key: $env, env: $env,
		  region: "europe-west2", zone: "europe-west2-a",
		  instance_name: ("sl-" + $env + "-demo"), internal_ip: "10.4.0.7",
		  app_port: $port, state_bucket: "acme-tfstate",
		  state_prefix: ("osramp/environments/" + $env),
		  deploy_sa: "deployer@acme-real-project-42.iam.gserviceaccount.com",
		  operator_sa: $op, access_mode: "iap", hostname: "demo-7.acme.example"}
		 | if $op == "" then del(.operator_sa) else . end' \
		>"${root}/deploy/gcp/${ENV_KEY}.handoff.json"
}

make_report() {
	local outcome="$1" commit="${2:-${COMMIT_2_SHORT}}"
	local src="${BATS_TEST_TMPDIR}/remote-reports"
	rm -rf "${src}"
	mkdir -p "${src}"
	jq -n --arg o "${outcome}" --arg c "${commit}" \
		'{outcome: $o, commit: $c, total_stages: 6, passed: 6}' >"${src}/summary.json"
	printf 'remote pipeline log\n' >"${src}/pipeline-remote.log"
	export STUB_REPORT_SRC="${src}"
}

# ---------------------------------------------------------------------------
# Ref Resolution & Refusal Tests
# ---------------------------------------------------------------------------

@test "DEMOREF unset GCP_TF_DEMO_REF is refused with DEMO-REF-UNSET and zero gcloud calls" {
	unset GCP_TF_DEMO_REF
	run "${driver}" up
	[ "$status" -eq 2 ]
	[[ "${output}" == *"DEMO-REF-UNSET"* ]] || {
		echo "output did not contain DEMO-REF-UNSET: ${output}"
		return 1
	}
	# gcloud stub log must be completely empty: no cloud calls were made
	[ ! -s "${STUB_GCLOUD_LOG}" ] || {
		echo "gcloud stub was called on unset ref: $(cat "${STUB_GCLOUD_LOG}")"
		return 1
	}
}

@test "DEMOREF empty GCP_TF_DEMO_REF is refused with DEMO-REF-UNSET and zero gcloud calls" {
	GCP_TF_DEMO_REF="" run "${driver}" up
	[ "$status" -eq 2 ]
	[[ "${output}" == *"DEMO-REF-UNSET"* ]] || {
		echo "output did not contain DEMO-REF-UNSET: ${output}"
		return 1
	}
	[ ! -s "${STUB_GCLOUD_LOG}" ] || {
		echo "gcloud stub was called on empty ref: $(cat "${STUB_GCLOUD_LOG}")"
		return 1
	}
}

@test "DEMOREF unknown ref is refused with DEMO-REF-UNRESOLVED and leaves no worktree" {
	local wt_before
	wt_before="$(git -C "${root}" worktree list --porcelain | grep -c '^worktree ')"

	GCP_TF_DEMO_REF="nonexistent-branch-or-tag-xyz" run "${driver}" up
	[ "$status" -eq 2 ]
	[[ "${output}" == *"DEMO-REF-UNRESOLVED"* ]] || {
		echo "output did not contain DEMO-REF-UNRESOLVED: ${output}"
		return 1
	}

	local wt_after
	wt_after="$(git -C "${root}" worktree list --porcelain | grep -c '^worktree ')"
	[ "$wt_before" -eq "$wt_after" ] || {
		echo "worktrees leaked: before=${wt_before} after=${wt_after}"
		return 1
	}
}

# ---------------------------------------------------------------------------
# Payload Construction from Named Ref
# ---------------------------------------------------------------------------

@test "DEMOREF payload equals git archive of the named ref" {
	local out="${BATS_TEST_TMPDIR}/payload-v1.tar.gz"
	GCP_TF_DEMO_REF="v1-branch" run "${driver}" payload "${out}"
	[ "$status" -eq 0 ]
	[ -f "${out}" ]

	# Extract and verify app.ts content matches commit 1 (v1), not commit 2 (HEAD)
	local content
	content="$(tar -xOf "${out}" d2-signalloom/app.ts)"
	[ "$content" = "the app v1" ]

	# Compare tarball sha256 with git archive of commit 1
	local payload_sha expected_sha
	payload_sha="$(sha256sum "${out}" | awk '{print $1}')"
	expected_sha="$(git -C "${root}" archive --format=tar.gz "${COMMIT_1_SHA}" | sha256sum | awk '{print $1}')"
	[ "$payload_sha" = "$expected_sha" ]
}

@test "DEMOREF dirty principal tree does not change payload and run proceeds for named ref" {
	# Add dirty uncommitted changes in principal repo
	printf 'dirty principal uncommitted edit\n' >>"${root}/d2-signalloom/app.ts"

	local out="${BATS_TEST_TMPDIR}/payload-dirty-ref.tar.gz"
	GCP_TF_DEMO_REF="v1-branch" run "${driver}" payload "${out}"
	[ "$status" -eq 0 ]
	[ -f "${out}" ]

	# Content in archive is clean v1
	local content
	content="$(tar -xOf "${out}" d2-signalloom/app.ts)"
	[ "$content" = "the app v1" ]

	# Hash matches git archive of clean commit 1 exactly
	local payload_sha expected_sha
	payload_sha="$(sha256sum "${out}" | awk '{print $1}')"
	expected_sha="$(git -C "${root}" archive --format=tar.gz "${COMMIT_1_SHA}" | sha256sum | awk '{print $1}')"
	[ "$payload_sha" = "$expected_sha" ]
}

# ---------------------------------------------------------------------------
# Explicit HEAD & Dirty Tree Matrix
# ---------------------------------------------------------------------------

@test "DEMOREF explicit HEAD on clean tree proceeds" {
	local out="${BATS_TEST_TMPDIR}/payload-head-clean.tar.gz"
	GCP_TF_DEMO_REF="HEAD" run "${driver}" payload "${out}"
	[ "$status" -eq 0 ]
	[ -f "${out}" ]

	local content
	content="$(tar -xOf "${out}" d2-signalloom/app.ts)"
	[ "$content" = "the app v2" ]
}

@test "DEMOREF explicit HEAD on dirty tree is refused without ALLOW_DIRTY" {
	printf 'uncommitted edit\n' >>"${root}/d2-signalloom/app.ts"
	local out="${BATS_TEST_TMPDIR}/payload-head-dirty.tar.gz"
	GCP_TF_DEMO_REF="HEAD" run "${driver}" payload "${out}"
	[ "$status" -eq 2 ]
	[[ "${output}" == *"uncommitted changes"* ]]
	[[ "${output}" == *"GCP_TF_DEMO_ALLOW_DIRTY=1"* ]]
}

@test "DEMOREF explicit HEAD on dirty tree with ALLOW_DIRTY=1 proceeds with warning" {
	printf 'uncommitted edit\n' >>"${root}/d2-signalloom/app.ts"
	local out="${BATS_TEST_TMPDIR}/payload-head-allowed.tar.gz"
	GCP_TF_DEMO_REF="HEAD" GCP_TF_DEMO_ALLOW_DIRTY=1 run "${driver}" payload "${out}"
	[ "$status" -eq 0 ]
	[[ "${output}" == *"uncommitted changes are NOT in this run"* ]]
	[ -f "${out}" ]
}

# ---------------------------------------------------------------------------
# Surface Receipt and Hand-off Preservation
# ---------------------------------------------------------------------------

@test "DEMOREF receipt .commit carries short ref SHA and hand-off gains source_*" {
	make_report PASS "${COMMIT_1_SHORT}"
	GCP_TF_DEMO_REF="v1-branch" run "${driver}" up
	[ "$status" -eq 0 ]

	# Check receipt .commit is short SHA of commit 1
	local receipt="${surfaces}/${ENV_KEY}.on-vm.json"
	[ -f "${receipt}" ]
	local receipt_commit receipt_branch
	receipt_commit="$(jq -r '.commit' "${receipt}")"
	receipt_branch="$(jq -r '.branch' "${receipt}")"
	[ "${receipt_commit}" = "${COMMIT_1_SHORT}" ]
	[ "${receipt_branch}" = "v1-branch" ]

	# Check hand-off file has source_ref, source_sha, source_recorded_at
	local hfile="${root}/deploy/gcp/${ENV_KEY}.handoff.json"
	[ -f "${hfile}" ]
	run jq -e '.source_ref == "v1-branch" and .source_sha == "'"${COMMIT_1_SHA}"'" and (.source_recorded_at | test("^\\d{4}-\\d{2}-\\d{2}T"))' "${hfile}"
	[ "$status" -eq 0 ]
}

@test "DEMOREF source_* fields survive make gcp-tf-handoff regeneration" {
	make_report PASS "${COMMIT_1_SHORT}"
	GCP_TF_DEMO_REF="v1-branch" run "${driver}" up
	[ "$status" -eq 0 ]

	local hfile="${root}/deploy/gcp/${ENV_KEY}.handoff.json"
	local orig_ref orig_sha orig_rec
	orig_ref="$(jq -r '.source_ref' "${hfile}")"
	orig_sha="$(jq -r '.source_sha' "${hfile}")"
	orig_rec="$(jq -r '.source_recorded_at' "${hfile}")"
	[ "${orig_ref}" = "v1-branch" ]
	[ "${orig_sha}" = "${COMMIT_1_SHA}" ]

	# Regenerate hand-off using the Makefile recipe
	# Mock terraform output json via STUB_TF_OUTPUT_JSON and run gcp-tf-handoff
	local stub_output
	stub_output='{
	  "target_env": { "value": "demo-7" },
	  "target_environment": { "value": {
	    "kind": "demo", "region": "europe-west2", "zone": "europe-west2-a", "app_port": 8080, "hostname": "demo-7.acme.example"
	  } },
	  "instance_name": { "value": "sl-demo-7-demo" },
	  "internal_ip": { "value": "10.4.0.7" },
	  "operator_sa": { "value": "sl-operator@acme-real-project-42.iam.gserviceaccount.com" },
	  "integration_inputs": { "value": { "project_id": "acme-real-project-42", "access_mode": "iap" } }
	}'

	# Ensure stub terraform is on PATH
	cat > "${stubdir}/terraform" <<-STUB
	#!/usr/bin/env bash
	for a in "\$@"; do
	  if [ "\$a" = "output" ]; then
	    cat <<'EOF'
${stub_output}
EOF
	    exit 0
	  fi
	done
	exit 0
	STUB
	chmod +x "${stubdir}/terraform"

	local fixture="${BATS_TEST_TMPDIR}/fixture-demo-7"
	mkdir -p "${fixture}/.terraform-demo-7"
	cat > "${fixture}/.terraform-demo-7/terraform.tfstate" <<-JSON
	{"version":3,"backend":{"type":"gcs","config":{"bucket":"acme-tfstate","prefix":"osramp/environments/demo-7"}}}
	JSON

	run make -C "${REPO_ROOT}" gcp-tf-handoff ENV=demo-7 TF_STATE_BUCKET=acme-tfstate \
		TF_ROOT_ENV="${fixture}" \
		GCP_TF_HANDOFF_DIR="${root}/deploy/gcp" GCP_TF_IMPERSONATE=deployer@acme.example \
		GCP_TF_DEPLOY_SA_FILE="${root}/deploy/gcp/deploy-sa"
	[ "$status" -eq 0 ] || { echo "make failed: ${output}"; return 1; }

	# Verify source_* fields survived
	local new_ref new_sha new_rec
	new_ref="$(jq -r '.source_ref' "${hfile}")"
	new_sha="$(jq -r '.source_sha' "${hfile}")"
	new_rec="$(jq -r '.source_recorded_at' "${hfile}")"

	[ "${new_ref}" = "${orig_ref}" ]
	[ "${new_sha}" = "${orig_sha}" ]
	[ "${new_rec}" = "${orig_rec}" ]
}

@test "DEMOREF git worktree list is unchanged before and after the suite runs" {
	local wt_before
	wt_before="$(git -C "${root}" worktree list --porcelain | grep -c '^worktree ')"

	local out="${BATS_TEST_TMPDIR}/payload-check.tar.gz"
	GCP_TF_DEMO_REF="v1-branch" run "${driver}" payload "${out}"
	[ "$status" -eq 0 ]

	local wt_after
	wt_after="$(git -C "${root}" worktree list --porcelain | grep -c '^worktree ')"
	[ "$wt_before" -eq "$wt_after" ]
}
