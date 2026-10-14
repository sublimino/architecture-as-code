#!/usr/bin/env bats
#
# GCP demo lane: the hand-off and the surface receipts record the commit that
# was DEPLOYED, on every outcome that deployed a payload.
#
# Regression for the 2026-10 lane defect: every GCP lane carried
# `source_sha: null` / `source_ref: null` in its hand-off, and the tailnet
# receipt stamped a commit (4884c2e0) other than the one the pipeline reported
# running (c2335169). Two causes, one test each:
#
#   1. record_source_in_handoff ran only on PASS, so a lane whose pipeline
#      FAILED after the payload landed never recorded what it was running.
#   2. cmd_ts_test called capture_source_identity BEFORE it located the
#      hand-off, so the recorded SHA was never consulted and the receipt
#      stamped the operator's local HEAD (or whatever GCP_TF_DEMO_REF now
#      resolves to) instead of the payload.
#
# Offline: stub gcloud, stub tailscale, throwaway git repo. No GCP, no cluster.
# Named `terraform-*.bats` so `make gcp-tf-validate` picks it up by wildcard.

setup_file() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export REPO_ROOT
	export DRIVER_SRC="${REPO_ROOT}/scripts/gcp-tf/demo-up.sh"
	export STUB_SRC="${REPO_ROOT}/test/fixtures/gcp-tf-demo/stub-gcloud"
	export DEX_STUB_SRC="${REPO_ROOT}/test/fixtures/gcp-tf-tailscale/stub-dex-origin"
}

setup() {
	[ -x "${DRIVER_SRC}" ]
	[ -f "${STUB_SRC}" ]
	[ -f "${DEX_STUB_SRC}" ]

	ENV_KEY="demo-7"
	root="${BATS_TEST_TMPDIR}/repo"
	stubdir="${BATS_TEST_TMPDIR}/bin"
	surfaces="${BATS_TEST_TMPDIR}/surfaces"
	driver="${root}/scripts/gcp-tf/demo-up.sh"
	hfile="${root}/deploy/gcp/${ENV_KEY}.handoff.json"

	mkdir -p "${stubdir}" "${surfaces}"
	cp "${STUB_SRC}" "${stubdir}/gcloud"
	cp "${DEX_STUB_SRC}" "${stubdir}/dex-origin"
	# A tailscale that knows no nodes: ts-test fails at R1 and files a FAIL
	# receipt, which is the receipt-stamping path under test.
	printf '#!/usr/bin/env bash\nexit 1\n' >"${stubdir}/tailscale"
	printf '#!/usr/bin/env bash\nexit 0\n' >"${stubdir}/probe-ok"
	printf '#!/usr/bin/env bash\nexit 1\n' >"${stubdir}/port-free"
	chmod +x "${stubdir}"/*

	make_repo
	write_handoff

	export PATH="${stubdir}:${PATH}"
	export STUB_GCLOUD_LOG="${BATS_TEST_TMPDIR}/gcloud.log"
	export STUB_DEX_LOG="${BATS_TEST_TMPDIR}/dex.log"
	export STUB_VM_FS="${BATS_TEST_TMPDIR}/vmfs"
	mkdir -p "${STUB_VM_FS}"
	: >"${STUB_GCLOUD_LOG}"
	: >"${STUB_DEX_LOG}"
	export GCP_TF_DEMO_DEX_ORIGIN_CMD="${stubdir}/dex-origin"
	export GCP_TF_DEMO_TAILSCALE="${stubdir}/tailscale"
	export GCP_TF_DEMO_REPO_ROOT="${root}"
	export GCP_TF_DEMO_ENV="${ENV_KEY}"
	export GCP_TF_HANDOFF_DIR="${root}/deploy/gcp"
	export GCP_TF_DEMO_REPORT_DIR="${root}/demo-reports"
	export GCP_TF_DEMO_SURFACE_DIR="${surfaces}"
	export GCP_TF_DEMO_SSH_WAIT_ATTEMPTS=2
	export GCP_TF_DEMO_SSH_WAIT_INTERVAL=0
	export GCP_TF_DEMO_TIMEOUT_MINUTES=1
	export AFM_REQUIRED=0
	export GCP_TF_DEMO_PORT_PROBE="${stubdir}/probe-ok"
	export GCP_TF_DEMO_TUNNEL_WAIT_SECONDS=2
	export STUB_TUNNEL_HOLD=1
	export GCP_TF_DEMO_PREFLIGHT_PORT_PROBE="${stubdir}/port-free"
	unset GCP_TF_DEMO_REF
}

make_repo() {
	mkdir -p "${root}/scripts/gcp-tf" "${root}/scripts/lib" "${root}/deploy/gcp" "${root}/d2-signalloom"
	cp "${DRIVER_SRC}" "${driver}"
	chmod +x "${driver}"
	cp "${REPO_ROOT}/scripts/lib/wait.sh" "${root}/scripts/lib/wait.sh"
	printf '#!/usr/bin/env bash\necho "demo-pipeline ran"\n' >"${root}/scripts/gcp-tf/demo-pipeline.sh"
	chmod +x "${root}/scripts/gcp-tf/demo-pipeline.sh"
	printf 'all: ; @true\n' >"${root}/Makefile"
	printf 'the app v1\n' >"${root}/d2-signalloom/app.ts"
	printf '*.handoff.json\ndemo-reports*/\n' >"${root}/.gitignore"

	git -C "${root}" init -q
	git -C "${root}" add -A
	git -C "${root}" -c user.name=t -c user.email=t@t commit -q -m "fixture 1" --no-gpg-sign
	COMMIT_1_SHA="$(git -C "${root}" rev-parse HEAD)"
	COMMIT_1_SHORT="$(git -C "${root}" rev-parse --short HEAD)"
	printf 'the app v2\n' >"${root}/d2-signalloom/app.ts"
	git -C "${root}" add -A
	git -C "${root}" -c user.name=t -c user.email=t@t commit -q -m "fixture 2" --no-gpg-sign
	COMMIT_2_SHORT="$(git -C "${root}" rev-parse --short HEAD)"
	git -C "${root}" branch v1-branch "${COMMIT_1_SHA}"
	[ "${COMMIT_1_SHORT}" != "${COMMIT_2_SHORT}" ]
}

write_handoff() {
	jq -n --arg env "${ENV_KEY}" \
		'{schema: "signalloom.gcp.handoff/v1", schema_version: 1,
		  project_id: "acme-real-project-42", environment_key: $env, env: $env,
		  region: "europe-west2", zone: "europe-west2-a",
		  instance_name: ("sl-" + $env + "-demo"), internal_ip: "10.4.0.7",
		  app_port: 8080, state_bucket: "acme-tfstate",
		  state_prefix: ("osramp/environments/" + $env),
		  deploy_sa: "deployer@acme-real-project-42.iam.gserviceaccount.com",
		  operator_sa: "sl-operator@acme-real-project-42.iam.gserviceaccount.com",
		  access_mode: "iap", hostname: "demo-7.acme.example"}' >"${hfile}"
}

make_report() {
	local outcome="$1" commit="$2" src="${BATS_TEST_TMPDIR}/remote-reports"
	rm -rf "${src}"
	mkdir -p "${src}"
	jq -n --arg o "${outcome}" --arg c "${commit}" \
		'{outcome: $o, commit: $c, total_stages: 6, passed: 3}' >"${src}/summary.json"
	printf 'remote pipeline log\n' >"${src}/pipeline-remote.log"
	export STUB_REPORT_SRC="${src}"
}

@test "SRCID a FAILED run that deployed a payload still records source_ref and source_sha" {
	make_report FAIL "${COMMIT_1_SHORT}"
	export STUB_PIPELINE_RC=1
	GCP_TF_DEMO_REF="v1-branch" run "${driver}" up
	[ "$status" -ne 0 ] || { echo "a FAIL verdict exited 0: ${output}"; return 1; }
	grep -q 'compute scp' "${STUB_GCLOUD_LOG}" || { echo "payload was never delivered; test premise broken"; return 1; }

	run jq -r '[.source_ref, .source_sha] | @tsv' "${hfile}"
	[ "$status" -eq 0 ]
	[ "${output}" = "v1-branch	${COMMIT_1_SHA}" ] || {
		echo "hand-off source after a FAILED deploy: '${output}' (want v1-branch/${COMMIT_1_SHA})"
		return 1
	}
}

@test "SRCID a run whose delivery failed does not record a source it never deployed" {
	make_report PASS "${COMMIT_1_SHORT}"
	export STUB_SCP_UP_RC=1
	GCP_TF_DEMO_REF="v1-branch" run "${driver}" up
	[ "$status" -ne 0 ]
	if grep -q 'demo-pipeline' "${STUB_GCLOUD_LOG}"; then
		echo "premise broken: the pipeline ran after a failed delivery"
		return 1
	fi
	run jq -r 'has("source_sha")' "${hfile}"
	[ "${output}" = "false" ] || { echo "undeployed run recorded a source: $(cat "${hfile}")"; return 1; }
}

@test "SRCID the tailnet receipt stamps the deployed payload SHA, not local HEAD" {
	jq --arg sha "${COMMIT_1_SHA}" '. + {source_ref: "v1-branch", source_sha: $sha}' "${hfile}" >"${hfile}.t"
	mv "${hfile}.t" "${hfile}"

	# Make passes GCP_TF_DEMO_REF='' when the operator did not set one.
	GCP_TF_DEMO_REF="" run "${driver}" ts-test
	[ "$status" -ne 0 ]
	run jq -r '.commit' "${surfaces}/${ENV_KEY}.tailnet.json"
	[ "$status" -eq 0 ]
	[ "${output}" = "${COMMIT_1_SHORT}" ] || {
		echo "tailnet receipt commit '${output}', deployed ${COMMIT_1_SHORT}, local HEAD ${COMMIT_2_SHORT}"
		return 1
	}
}

@test "SRCID the tailnet receipt ignores a GCP_TF_DEMO_REF that names a different commit than was deployed" {
	jq --arg sha "${COMMIT_1_SHA}" '. + {source_ref: "v1-branch", source_sha: $sha}' "${hfile}" >"${hfile}.t"
	mv "${hfile}.t" "${hfile}"

	GCP_TF_DEMO_REF="HEAD" run "${driver}" ts-test
	[ "$status" -ne 0 ]
	run jq -r '.commit' "${surfaces}/${ENV_KEY}.tailnet.json"
	[ "${output}" = "${COMMIT_1_SHORT}" ] || {
		echo "tailnet receipt commit '${output}' follows the ref named now, not the payload ${COMMIT_1_SHORT}"
		return 1
	}
}
