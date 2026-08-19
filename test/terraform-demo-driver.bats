#!/usr/bin/env bats
#
# The GCP demo lane: the local driver and the Make targets that call it.
#
# Named `terraform-*.bats` deliberately. `make gcp-tf-validate` runs
# `$(wildcard test/terraform-*.bats)`, so this suite is registered the moment it
# lands and cannot be forgotten by a hand-maintained list — the failure mode
# that left 33 suites in this repo passing and unasked. Reverting that glob to a
# list fails test/terraform-suite-registration.bats.
#
# Two halves, and the suite needs both:
#
#   The Make contract  — targets EXECUTED (not grepped) and asserted on what
#                        they refuse and what they forward.
#   The driver         — scripts/gcp-tf/demo-up.sh run end to end against a stub
#                        gcloud on PATH, so the real control flow executes with
#                        no cloud access, no credentials and no network.
#
# The verdict tests are the point of the file. On 2026-08-13 a missing summary
# was read as a pass twice in one day. PASS/FAIL/ABORTED/STALE each get a test,
# and each mutation below proves the classifier can actually go red.

setup_file() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export REPO_ROOT
	export MAKEFILE="${REPO_ROOT}/Makefile"
	export DRIVER_SRC="${REPO_ROOT}/scripts/gcp-tf/demo-up.sh"
	export STUB_SRC="${REPO_ROOT}/test/fixtures/gcp-tf-demo/stub-gcloud"
}

# Every target this suite owns. Written once so a target added to the family
# cannot be added to half the assertions.
DEMO_TARGETS="gcp-tf-demo-up gcp-tf-demo-test gcp-tf-connect gcp-tf-demo-status"
CLOUD_TARGETS="gcp-tf-demo-up gcp-tf-demo-test gcp-tf-connect"

setup() {
	# Presence before behaviour, always. A suite driving a script that was never
	# written reports whatever the shell does with a missing file, and this repo
	# has shipped that shape before.
	[ -f "${MAKEFILE}" ]
	[ -f "${DRIVER_SRC}" ]
	[ -x "${DRIVER_SRC}" ]
	[ -f "${STUB_SRC}" ]
	grep -q '^# END GCP Terraform platform block' "${MAKEFILE}"

	ENV_KEY="demo-7"
	root="${BATS_TEST_TMPDIR}/repo"
	stubdir="${BATS_TEST_TMPDIR}/bin"
	log="${BATS_TEST_TMPDIR}/gcloud.log"
	driver="${root}/scripts/gcp-tf/demo-up.sh"

	mkdir -p "${stubdir}"
	cp "${STUB_SRC}" "${stubdir}/gcloud"
	chmod +x "${stubdir}/gcloud"
	: >"${log}"

	make_repo
	write_handoff

	export PATH="${stubdir}:${PATH}"
	export STUB_GCLOUD_LOG="${log}"
	export GCP_TF_DEMO_REPO_ROOT="${root}"
	export GCP_TF_DEMO_ENV="${ENV_KEY}"
	export GCP_TF_HANDOFF_DIR="${root}/deploy/gcp"
	export GCP_TF_DEMO_REPORT_DIR="${root}/demo-reports"
	export GCP_TF_DEMO_SSH_WAIT_ATTEMPTS=2
	export GCP_TF_DEMO_SSH_WAIT_INTERVAL=0
	export GCP_TF_DEMO_TIMEOUT_MINUTES=1

	# The VM's filesystem, so the post-transfer size check has real bytes to
	# read back rather than a canned answer.
	export STUB_VM_FS="${BATS_TEST_TMPDIR}/vmfs"
	mkdir -p "${STUB_VM_FS}"

	# The tunnel probe is injectable precisely so the connect path is drivable
	# with no listener. Default success; the failure tests point it at `false`.
	printf '#!/usr/bin/env bash\nexit 0\n' >"${stubdir}/probe-ok"
	printf '#!/usr/bin/env bash\nexit 1\n' >"${stubdir}/probe-fail"
	chmod +x "${stubdir}/probe-ok" "${stubdir}/probe-fail"
	export GCP_TF_DEMO_PORT_PROBE="${stubdir}/probe-ok"
	export GCP_TF_DEMO_TUNNEL_WAIT_SECONDS=2
	export STUB_TUNNEL_HOLD=1
}

# A fixture checkout carrying one of everything the exclusion list names, so
# "the payload excludes secrets" is a statement about material that is really
# there. A test whose fixture contains no key cannot observe a leaked key.
make_repo() {
	mkdir -p "${root}/scripts/gcp-tf" "${root}/deploy/gcp" "${root}/.keys" \
		"${root}/node_modules/left-pad" "${root}/terraform/environments/.terraform-demo-7" \
		"${root}/d2-signalloom"

	cp "${DRIVER_SRC}" "${driver}"
	chmod +x "${driver}"

	printf '#!/usr/bin/env bash\necho "demo-pipeline ran"\n' >"${root}/scripts/gcp-tf/demo-pipeline.sh"
	chmod +x "${root}/scripts/gcp-tf/demo-pipeline.sh"

	printf 'COSIGN PRIVATE KEY MATERIAL\n' >"${root}/.keys/cosign.key"
	printf 'project_id = "acme-real-project-42"\n' >"${root}/deploy/gcp/environments.tfvars"
	printf 'deployer@acme-real-project-42.iam.gserviceaccount.com\n' >"${root}/deploy/gcp/deploy-sa"
	printf 'module.exports = 1\n' >"${root}/node_modules/left-pad/index.js"
	printf 'cached provider\n' >"${root}/terraform/environments/.terraform-demo-7/lock"
	printf 'all: ; @true\n' >"${root}/Makefile"
	printf 'the app\n' >"${root}/d2-signalloom/app.ts"

	# The fixture's .gitignore MIRRORS the real repo's protections, and that is
	# load-bearing rather than tidiness. The payload is `git archive HEAD`, so
	# "no secret can ride along" is a claim about what is TRACKED. A fixture
	# without these lines would track the key and the tfvars, and the exclusion
	# test would fail — correctly, because in that repo the guarantee genuinely
	# would not hold.
	cat >"${root}/.gitignore" <<'IGNORE'
.keys/
node_modules/
.terraform*
*.tfvars
*.handoff.json
deploy/gcp/deploy-sa
demo-reports*/
IGNORE

	# A REAL git repo. `git archive` needs a commit to archive, the STALE test
	# needs a commit for the driver to stamp and compare against, and the
	# dirty-tree guard needs a clean tree to not fire against.
	git -C "${root}" init -q
	git -C "${root}" add -A
	git -C "${root}" -c user.name=t -c user.email=t@t \
		commit -q -m "fixture" --no-gpg-sign
	FIXTURE_COMMIT="$(git -C "${root}" rev-parse --short HEAD)"
}

# write_handoff [app_port] [operator_sa]
# An empty operator_sa deletes the field outright rather than blanking it, which
# is the shape a hand-off written before chunk A landed actually has.
write_handoff() {
	# `${2-...}` and not `${2:-...}`: the caller passes an EMPTY string to mean
	# "no operator SA in the hand-off", and the colon form would helpfully
	# replace that with the default — leaving the no-operator test driving a
	# fully-configured hand-off and asserting on a refusal that never fired.
	local port="${1:-30754}" op="${2-sl-operator@acme-real-project-42.iam.gserviceaccount.com}"
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

# A remote report bundle for the stub to hand back. Absence of one models a
# pipeline that died before writing anything.
make_report() {
	local outcome="$1" commit="${2:-${FIXTURE_COMMIT}}"
	local src="${BATS_TEST_TMPDIR}/remote-reports"
	rm -rf "${src}"
	mkdir -p "${src}"
	jq -n --arg o "${outcome}" --arg c "${commit}" \
		'{outcome: $o, commit: $c, total_stages: 6, passed: 6}' >"${src}/summary.json"
	printf 'remote pipeline log\n' >"${src}/pipeline-remote.log"
	export STUB_REPORT_SRC="${src}"
}

run_make() {
	run make -C "${REPO_ROOT}" "$@"
}

# Every gcloud invocation the stub recorded, one per line.
gcloud_log() {
	cat "${log}" 2>/dev/null || true
}

# ─── Static properties ──────────────────────────────────────────────────────

@test "DEMODRIVER the driver is executable and shellcheck clean" {
	[ -x "${DRIVER_SRC}" ]
	command -v shellcheck >/dev/null || skip "shellcheck not installed"
	run shellcheck "${DRIVER_SRC}"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "DEMODRIVER the driver hardcodes no project, zone, instance or bucket" {
	# The hand-off is the only source of estate identity. A value typed here is
	# a value that goes stale silently and names the wrong estate.
	#
	# Presence first: a grep against a missing file reports "pattern absent",
	# which is a pass earned by scanning nothing.
	# Presence first. `[ "$status" -ne 0 ]` on a grep reads a MISSING FILE as
	# "pattern absent" — a pass earned by scanning nothing.
	[ -f "${DRIVER_SRC}" ]

	# Not driven through `run`: a pipeline puts `run` in a subshell, so $status
	# and $output never come back and the assertion silently measures the empty
	# string.
	#
	# Three exemptions, all constants of the protocol rather than of the estate:
	# 127.0.0.1 (the loopback in the /etc/hosts line and the curl --resolve,
	# which are the POINT of the connect output), 35.235.240.0/20 (Google's
	# fixed IAP source range, quoted in the firewall diagnosis), and 0.0.0.0
	# (the wildcard bind address the VM-side forward must use, because a forward
	# bound to loopback is unreachable through an IAP tunnel that connects to the
	# instance's internal IP). None can go stale when the estate is rebuilt,
	# which is the property being protected.
	local hits
	hits="$(grep -nE '(cp-dev-ajm|acme-real-project|[a-z0-9-]+\.iam\.gserviceaccount\.com|europe-west[0-9]-[a-z]|((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9]))' "${DRIVER_SRC}" |
		grep -v -e '127\.0\.0\.1' -e '35\.235\.240\.0' -e '0\.0\.0\.0' || true)"
	[ -z "$hits" ] || {
		echo "hardcoded estate identity in the driver:"
		echo "$hits"
		return 1
	}

	# The scan must be capable of finding something, or its silence is worthless.
	local control
	control="$(printf '%s\n' 'sa = "x@cp-dev-ajm.iam.gserviceaccount.com"' |
		grep -cE '[a-z0-9-]+\.iam\.gserviceaccount\.com' || true)"
	[ "$control" -eq 1 ]
}

# ─── The Make contract ──────────────────────────────────────────────────────

@test "DEMODRIVER every demo target exists as a real make target" {
	# Presence, not just absence. A contract test that only greps for a refusal
	# passes hardest when the target has been DELETED.
	for t in ${DEMO_TARGETS}; do
		run make -C "${REPO_ROOT}" -n "$t" ENV=demo-9
		[[ "${output}" != *"No rule to make target"* ]] || {
			echo "target ${t} does not exist"
			return 1
		}
	done
}

@test "DEMODRIVER every demo target is declared .PHONY" {
	for t in ${DEMO_TARGETS}; do
		grep -Eq "^\.PHONY:( .*)? ${t}( |$)" "${MAKEFILE}" || {
			echo "${t} is not declared .PHONY"
			return 1
		}
	done
}

@test "DEMODRIVER every demo target appears in make help" {
	run_make help
	[ "$status" -eq 0 ]
	for t in ${DEMO_TARGETS}; do
		[[ "${output}" == *"${t}"* ]] || {
			echo "${t} is missing from make help — it has no '## ' comment"
			return 1
		}
	done
}

@test "DEMODRIVER every demo target refuses to run without ENV and says so" {
	for t in ${DEMO_TARGETS}; do
		run_make "$t"
		[ "$status" -ne 0 ] || {
			echo "${t} succeeded with no ENV"
			return 1
		}
		[[ "${output}" == *"ENV is required"* ]] || {
			echo "${t} failed without naming ENV as the cause: ${output}"
			return 1
		}
	done
}

@test "DEMODRIVER every demo target rejects a production-shaped key" {
	for t in ${DEMO_TARGETS}; do
		run_make "$t" ENV=prod-1
		[ "$status" -ne 0 ] || {
			echo "${t} accepted ENV=prod-1"
			return 1
		}
		[[ "${output}" == *"not a valid environment key"* ]] || {
			echo "${t} rejected prod-1 without explaining why: ${output}"
			return 1
		}
	done
}

@test "DEMODRIVER every cloud-reaching demo target requires impersonation" {
	# Reuses the block's own gcp_tf_require_impersonation. The reachable
	# accident it models: a deploy identity IS configured for the checkout and
	# the value that gets exported has been blanked on the command line.
	for t in ${CLOUD_TARGETS}; do
		run make -C "${REPO_ROOT}" "$t" ENV=demo-9 \
			GCP_TF_DEPLOY_SA_FILE=/dev/null TF_DEPLOY_SA=deployer@example.iam.gserviceaccount.com \
			GCP_TF_IMPERSONATE=
		[ "$status" -ne 0 ] || {
			echo "${t} ran with impersonation blanked"
			return 1
		}
		[[ "${output}" == *"without impersonation"* ]] || {
			echo "${t} refused without naming impersonation: ${output}"
			return 1
		}
	done
}

@test "DEMODRIVER the demo targets forward ENV to the driver" {
	run make -C "${REPO_ROOT}" -n gcp-tf-connect ENV=demo-9
	[ "$status" -eq 0 ]
	[[ "${output}" == *"GCP_TF_DEMO_ENV='demo-9'"* ]] || {
		echo "ENV is not forwarded to the driver: ${output}"
		return 1
	}
	[[ "${output}" == *"demo-up.sh' connect"* ]] || {
		echo "gcp-tf-connect does not invoke the driver's connect subcommand: ${output}"
		return 1
	}
}

# ─── Configuration comes from the hand-off ──────────────────────────────────

@test "DEMODRIVER an absent hand-off fails loudly and names the target that writes it" {
	rm -f "${root}/deploy/gcp/${ENV_KEY}.handoff.json"
	run "${driver}" up
	[ "$status" -ne 0 ]
	[[ "${output}" == *"no hand-off for ENV=${ENV_KEY}"* ]]
	[[ "${output}" == *"make gcp-tf-handoff"* ]] || {
		echo "the failure did not name the target that produces the hand-off: ${output}"
		return 1
	}
}

@test "DEMODRIVER a hand-off for another environment is refused" {
	# Reading it would point the whole run at the wrong estate, silently.
	jq '.environment_key = "demo-99" | .env = "demo-99"' \
		"${root}/deploy/gcp/${ENV_KEY}.handoff.json" >"${root}/x.json"
	mv "${root}/x.json" "${root}/deploy/gcp/${ENV_KEY}.handoff.json"
	run "${driver}" up
	[ "$status" -ne 0 ]
	[[ "${output}" == *"describes environment 'demo-99'"* ]]
}

@test "DEMODRIVER a hand-off with no operator SA is refused, naming osLoginExternalUser" {
	write_handoff 30754 ""
	run "${driver}" up
	[ "$status" -ne 0 ]
	[[ "${output}" == *"operator service account"* ]]
	[[ "${output}" == *"osLoginExternalUser"* ]] || {
		echo "the refusal did not explain the external-operator rule: ${output}"
		return 1
	}
}

@test "DEMODRIVER GCP_TF_DEMO_OPERATOR_SA overrides an absent hand-off field" {
	write_handoff 30754 ""
	make_report PASS
	GCP_TF_DEMO_OPERATOR_SA="override@acme.iam.gserviceaccount.com" run "${driver}" up
	[ "$status" -eq 0 ]
	[[ "$(gcloud_log)" == *"--impersonate-service-account=override@acme.iam.gserviceaccount.com"* ]]
}

# ─── ssh-agent and impersonation, as behaviour ──────────────────────────────

@test "DEMODRIVER every gcloud call sees an EMPTY SSH_AUTH_SOCK" {
	# Driven with a populated agent in the environment, because a test run with
	# no agent set would pass against a driver that does nothing at all.
	make_report PASS
	SSH_AUTH_SOCK=/tmp/agent-that-refuses.sock run "${driver}" up
	[ "$status" -eq 0 ]

	local calls
	calls="$(gcloud_log)"
	[ -n "$calls" ] || {
		echo "the stub gcloud was never invoked — this test measured nothing"
		return 1
	}
	local bad
	bad="$(printf '%s\n' "$calls" | grep -v 'SSH_AUTH_SOCK=\[\]' || true)"
	[ -z "$bad" ] || {
		echo "gcloud was called with a populated ssh-agent socket:"
		echo "$bad"
		return 1
	}
}

@test "DEMODRIVER every gcloud call carries the operator impersonation flag" {
	make_report PASS
	run "${driver}" up
	[ "$status" -eq 0 ]

	local calls bad
	calls="$(gcloud_log)"
	[ -n "$calls" ] || {
		echo "the stub gcloud was never invoked — this test measured nothing"
		return 1
	}
	bad="$(printf '%s\n' "$calls" | grep -v -- '--impersonate-service-account=' || true)"
	[ -z "$bad" ] || {
		echo "gcloud was called without impersonation:"
		echo "$bad"
		return 1
	}
}

# ─── The payload ────────────────────────────────────────────────────────────

@test "DEMODRIVER the payload carries the code and excludes every secret" {
	local out="${BATS_TEST_TMPDIR}/payload.tar.gz"
	run "${driver}" payload "${out}"
	[ "$status" -eq 0 ]
	[ -f "${out}" ]

	local listing
	listing="$(tar -tzf "${out}")"

	# Positive control FIRST. An empty tarball excludes every secret perfectly
	# and delivers nothing, and would pass every assertion below.
	#
	# No `./` prefix: git archive emits repo-relative paths, where a tar of the
	# working tree emitted `./`-prefixed ones. Matching the old shape here would
	# have silently turned the positive control into a permanent failure.
	[[ "${listing}" == *"d2-signalloom/app.ts"* ]] || {
		echo "the payload does not contain the application source — it is not a delivery"
		return 1
	}
	[[ "${listing}" == *"scripts/gcp-tf/demo-pipeline.sh"* ]] || {
		echo "the payload does not contain the pipeline it exists to run"
		return 1
	}

	local leaked
	leaked="$(printf '%s\n' "${listing}" |
		grep -E '(^|/)\.git/|(^|/)\.keys/|(^|/)node_modules/|\.terraform|\.tfvars|\.handoff\.json|deploy/gcp/deploy-sa' || true)"
	[ -z "${leaked}" ] || {
		echo "excluded material rode along in the payload:"
		echo "${leaked}"
		return 1
	}
}

@test "DEMODRIVER the payload is built with git archive, not a tar of the working tree" {
	# Asserting the MECHANISM, not only its effect. A tar with the right
	# excludes produces a payload that passes every content assertion above and
	# has none of the guarantee: excludes are correct while somebody maintains
	# them, tracked-files-only is correct by construction.
	[ -f "${DRIVER_SRC}" ]
	grep -q 'archive --format=tar.gz' "${DRIVER_SRC}" || {
		echo "the payload is no longer built with git archive"
		return 1
	}
	local excludes
	excludes="$(grep -c -- "--exclude=" "${DRIVER_SRC}" || true)"
	[ "$excludes" -eq 0 ] || {
		echo "the payload has grown ${excludes} tar --exclude flags; the guarantee is tracked-files-only"
		return 1
	}
}

@test "DEMODRIVER an untracked secret cannot reach the payload at all" {
	# The positive statement of the guarantee: the fixture's key is present on
	# disk and simply is not in the archive, with no exclusion doing the work.
	[ -f "${root}/.keys/cosign.key" ]
	local out="${BATS_TEST_TMPDIR}/tracked-only.tar.gz"
	run "${driver}" payload "${out}"
	[ "$status" -eq 0 ]

	local listing
	listing="$(tar -tzf "${out}")"
	[[ "${listing}" != *"cosign.key"* ]] || {
		echo "an untracked signing key reached the payload"
		return 1
	}
	[[ "${listing}" == *"d2-signalloom/app.ts"* ]] || {
		echo "the payload carries nothing — it excludes the key by being empty"
		return 1
	}
}

@test "DEMODRIVER a dirty working tree is refused, because git archive ships HEAD" {
	# Otherwise the run tests HEAD while the operator reads their edits, and
	# stamps the report with HEAD's commit — accurate about a tree nobody is
	# looking at.
	printf 'uncommitted edit\n' >>"${root}/d2-signalloom/app.ts"
	make_report PASS
	run "${driver}" up
	[ "$status" -ne 0 ]
	[[ "${output}" == *"uncommitted changes"* ]]
	[[ "${output}" == *"GCP_TF_DEMO_ALLOW_DIRTY=1"* ]] || {
		echo "the refusal did not offer the explicit override: ${output}"
		return 1
	}
	[[ "${output}" == *"d2-signalloom/app.ts"* ]] || {
		echo "the refusal did not name the dirty file: ${output}"
		return 1
	}
}

@test "DEMODRIVER GCP_TF_DEMO_ALLOW_DIRTY proceeds but says what is not in the run" {
	printf 'uncommitted edit\n' >>"${root}/d2-signalloom/app.ts"
	make_report PASS
	GCP_TF_DEMO_ALLOW_DIRTY=1 run "${driver}" up
	[ "$status" -eq 0 ]
	[[ "${output}" == *"uncommitted changes are NOT in this run"* ]] || {
		echo "the override ran silently — the operator is not told what was skipped: ${output}"
		return 1
	}
}

# ─── Delivery is verified, not assumed ──────────────────────────────────────

@test "DEMODRIVER a payload that lands EMPTY fails the run" {
	# The historical shape: the transfer reports success and the file is zero
	# bytes, so chmod succeeds, the launch reports launched, and the log is
	# empty. Nothing anywhere goes red.
	export STUB_DELIVERY_BYTES=0
	make_report PASS
	run "${driver}" up
	[ "$status" -ne 0 ] || {
		echo "a zero-byte delivery was accepted and the run reported success"
		return 1
	}
	[[ "${output}" == *"bytes and"* ]] || {
		echo "the size mismatch was not reported: ${output}"
		return 1
	}
}

@test "DEMODRIVER a payload that never arrives fails the run" {
	export STUB_DELIVERY_BYTES=MISSING
	make_report PASS
	run "${driver}" up
	[ "$status" -ne 0 ]
	[[ "${output}" == *"not on"* ]]
	[[ "${output}" == *"do NOT read"* ]] || {
		echo "an absent payload was reported without warning against the run that follows: ${output}"
		return 1
	}
}

@test "DEMODRIVER a truncated payload fails the run" {
	export STUB_DELIVERY_BYTES=64
	make_report PASS
	run "${driver}" up
	[ "$status" -ne 0 ]
	[[ "${output}" == *"64 bytes"* ]] || {
		echo "the truncation was not reported with the byte counts: ${output}"
		return 1
	}
}

@test "DEMODRIVER the VM gets a throwaway git repo for Kustomize" {
	# git archive ships no .git, and Kustomize rejects `../base/` without one.
	make_report PASS
	run "${driver}" up
	[ "$status" -eq 0 ]
	[[ "$(gcloud_log)" == *"git init"* ]] || {
		echo "no snapshot repo was created on the VM; Kustomize will reject relative paths"
		return 1
	}
}

# ─── gcloud's impersonation warning must not become data ────────────────────

@test "DEMODRIVER the impersonation warning does not corrupt the VM state read" {
	# gcloud prints the warning to stderr on every API call, and vm_status
	# merges stderr in on purpose so it can classify auth failures. Unstripped,
	# the warning is glued onto the status, RUNNING never compares equal, and
	# the run aborts against a healthy VM.
	export STUB_VM_STATE=SUSPENDED
	make_report PASS
	run "${driver}" up
	[ "$status" -eq 0 ] || {
		echo "the run failed to read the VM state: ${output}"
		return 1
	}
	[[ "${output}" == *"resuming suspended"* ]] || {
		echo "SUSPENDED was not recognised — the state read is being corrupted: ${output}"
		return 1
	}
}

@test "DEMODRIVER the impersonation warning is kept out of the streamed output" {
	make_report PASS
	run "${driver}" up
	[ "$status" -eq 0 ]
	[[ "${output}" != *"using service account impersonation"* ]] || {
		echo "gcloud's per-API-call warning is polluting the operator's terminal"
		return 1
	}
	[[ "${output}" == *"stub-pipeline: stage output line 1"* ]] || {
		echo "the filter removed the pipeline's real output too"
		return 1
	}
}

@test "DEMODRIVER delivery is refused when the pipeline is not TRACKED" {
	# An untracked pipeline is the dangerous case, not a missing one: it sits
	# right there on disk, `git archive` does not carry it, and "it is right
	# there" is the most convincing possible wrong answer. So the file is left
	# in place and merely removed from the index.
	#
	# It is also added to .gitignore in the same commit, so the tree stays
	# CLEAN. Without that the dirty-tree guard fires first and this test passes
	# on the wrong refusal — a green that proves a different guard.
	git -C "${root}" rm -q --cached scripts/gcp-tf/demo-pipeline.sh
	printf 'scripts/gcp-tf/demo-pipeline.sh\n' >>"${root}/.gitignore"
	git -C "${root}" add .gitignore
	git -C "${root}" -c user.name=t -c user.email=t@t \
		commit -q -m "untrack the pipeline" --no-gpg-sign
	[ -f "${root}/scripts/gcp-tf/demo-pipeline.sh" ]
	[ -z "$(git -C "${root}" status --porcelain)" ]

	run "${driver}" payload "${BATS_TEST_TMPDIR}/p.tar.gz"
	[ "$status" -ne 0 ]
	[[ "${output}" == *"no TRACKED pipeline"* ]] || {
		echo "an untracked pipeline was not diagnosed as such: ${output}"
		return 1
	}
	[[ "${output}" == *"git archive"* ]]
}

# ─── The verdict — the whole reason this file exists ────────────────────────

@test "DEMODRIVER a PASS summary exits zero" {
	make_report PASS
	run "${driver}" up
	[ "$status" -eq 0 ]
	[[ "${output}" == *"PASS"* ]]
	[[ "${output}" == *"make gcp-tf-connect"* ]] || {
		echo "a passing run did not tell the operator how to open it: ${output}"
		return 1
	}
}

@test "DEMODRIVER a FAIL summary exits non-zero" {
	make_report FAIL
	run "${driver}" up
	[ "$status" -ne 0 ]
	[[ "${output}" == *"FAIL"* ]]
	[[ "${output}" == *"left RUNNING"* ]] || {
		echo "a failing run did not say the VM was left up for inspection: ${output}"
		return 1
	}
}

@test "DEMODRIVER an ABORTED summary exits non-zero and is not reported as a failure" {
	make_report ABORTED
	run "${driver}" up
	[ "$status" -ne 0 ]
	[[ "${output}" == *"ABORTED run, NOT a test failure"* ]] || {
		echo "an aborted run was not distinguished from a test failure: ${output}"
		return 1
	}
}

@test "DEMODRIVER a MISSING summary exits non-zero — absence is never a pass" {
	# The stub's collection fails without STUB_REPORT_SRC, which is exactly the
	# shape of a pipeline that died before writing anything. The pipeline itself
	# exits 0, so a driver that trusted the exit status would report success.
	unset STUB_REPORT_SRC
	export STUB_PIPELINE_RC=0
	run "${driver}" up
	[ "$status" -ne 0 ] || {
		echo "a run with NO verdict exited 0 — this is the 2026-08-13 defect"
		return 1
	}
	[[ "${output}" == *"no verdict was produced"* ]]
	[[ "${output}" == *"is never a pass"* ]] || {
		echo "the run did not state that an absent verdict is not a pass: ${output}"
		return 1
	}
}

@test "DEMODRIVER a summary stamped with another commit is STALE, not a pass" {
	make_report PASS "deadbee"
	run "${driver}" up
	[ "$status" -ne 0 ] || {
		echo "a summary describing a DIFFERENT run was accepted as this run's verdict"
		return 1
	}
	[[ "${output}" == *"stamped deadbee"* ]]
	[[ "${output}" == *"DIFFERENT run"* ]]
}

@test "DEMODRIVER a PASS summary next to a non-zero pipeline exit is a FAIL" {
	# A report saying PASS beside a red exit means the run died after writing
	# it. Exiting 0 on that pair is the same lie in a different file.
	make_report PASS
	export STUB_PIPELINE_RC=3
	run "${driver}" up
	[ "$status" -ne 0 ]
	[[ "${output}" == *"FAIL"* ]]
}

@test "DEMODRIVER the local summary records the verdict for later reading" {
	make_report FAIL
	run "${driver}" up
	[ "$status" -ne 0 ]
	[ -f "${root}/demo-reports/summary.json" ]
	run jq -r '.outcome' "${root}/demo-reports/summary.json"
	[ "$status" -eq 0 ]
	[ "$output" = "FAIL" ]
}

@test "DEMODRIVER the pipeline output is streamed locally, not swallowed" {
	# Watching a blank terminal for ninety minutes and receiving the log at the
	# end is not "streaming". Both halves are asserted: the operator's terminal,
	# and the file the run leaves behind.
	make_report PASS
	run "${driver}" up
	[ "$status" -eq 0 ]
	[[ "${output}" == *"stub-pipeline: stage output line 1"* ]] || {
		echo "the pipeline's output never reached the terminal: ${output}"
		return 1
	}
	[ -f "${root}/demo-reports/pipeline.log" ]
	run grep -c 'stub-pipeline: stage output' "${root}/demo-reports/pipeline.log"
	[ "$status" -eq 0 ]
	[ "$output" -ge 2 ]
}

@test "DEMODRIVER the test lane runs the pipeline with stage=test" {
	make_report PASS
	run "${driver}" test
	[ "$status" -eq 0 ]
	[[ "$(gcloud_log)" == *"SL_DEMO_STAGE=test"* ]] || {
		echo "the test lane did not ask the pipeline for the tests-only stage"
		return 1
	}
}

@test "DEMODRIVER the up lane runs the pipeline with stage=full" {
	make_report PASS
	run "${driver}" up
	[ "$status" -eq 0 ]
	[[ "$(gcloud_log)" == *"SL_DEMO_STAGE=full"* ]]
}

# ─── connect: the deliverable the human actually sees ───────────────────────

@test "DEMODRIVER connect prints the URL, the hosts line, the login and the smoke test" {
	run "${driver}" connect
	[ "$status" -eq 0 ]

	[[ "${output}" == *"https://dashboard.osramp.acme.local:30754"* ]] || {
		echo "connect did not print the dashboard URL: ${output}"
		return 1
	}
	[[ "${output}" == *"127.0.0.1 dashboard.osramp.acme.local"* ]] || {
		echo "connect did not print the exact /etc/hosts line: ${output}"
		return 1
	}
	[[ "${output}" == *"SELF-SIGNED"* ]] || {
		echo "connect did not warn that the certificate is self-signed: ${output}"
		return 1
	}
	[[ "${output}" == *"demo-user@signalloom.local"* ]]
	[[ "${output}" == *"password: demo-user"* ]] || {
		echo "connect did not print the Dex login: ${output}"
		return 1
	}
	[[ "${output}" == *"curl -k --resolve dashboard.osramp.acme.local:30754:127.0.0.1 https://dashboard.osramp.acme.local:30754/readyz"* ]] || {
		echo "connect did not print the one-line tunnel smoke test: ${output}"
		return 1
	}
}

@test "DEMODRIVER connect opens the IAP tunnel on the Dex-pinned port at both ends" {
	run "${driver}" connect
	[ "$status" -eq 0 ]
	local calls
	calls="$(gcloud_log)"
	[[ "${calls}" == *"start-iap-tunnel sl-demo-7-demo 30754"* ]] || {
		echo "the tunnel was not opened on the remote Dex port: ${calls}"
		return 1
	}
	[[ "${calls}" == *"--local-host-port=localhost:30754"* ]] || {
		echo "the tunnel was not bound to the local Dex port: ${calls}"
		return 1
	}
}

@test "DEMODRIVER connect fails cleanly when the tunnel never binds, rather than hanging" {
	export GCP_TF_DEMO_PORT_PROBE="${stubdir}/probe-fail"
	export STUB_TUNNEL_HOLD=10
	run "${driver}" connect
	[ "$status" -ne 0 ] || {
		echo "connect reported success against a tunnel that never bound"
		return 1
	}
	[[ "${output}" == *"did not bind localhost:30754"* ]] || {
		echo "connect did not say the tunnel failed to bind: ${output}"
		return 1
	}
}

@test "DEMODRIVER connect explains 4033 as an IAM failure, which it does not look like" {
	export GCP_TF_DEMO_PORT_PROBE="${stubdir}/probe-fail"
	export STUB_TUNNEL_STDERR="ERROR: [0] Error during local connection to [stdin]: Error while connecting [4033: 'not authorized']"
	run "${driver}" connect
	[ "$status" -ne 0 ]
	[[ "${output}" == *"iap.tunnelResourceAccessor"* ]] || {
		echo "4033 was not diagnosed as the missing IAP role: ${output}"
		return 1
	}
	[[ "${output}" == *"propagate"* ]] || {
		echo "the IAM propagation delay was not mentioned, so an immediate retry reads as the grant failing: ${output}"
		return 1
	}
}

@test "DEMODRIVER connect explains 4003 as TWO causes, not one" {
	# A closed port and a firewall rule are indistinguishable from the client.
	# Naming only one of them sends the reader to the wrong layer half the time.
	export GCP_TF_DEMO_PORT_PROBE="${stubdir}/probe-fail"
	export STUB_TUNNEL_STDERR="ERROR: [4003: 'failed to connect to backend']"
	run "${driver}" connect
	[ "$status" -ne 0 ]
	[[ "${output}" == *"Nothing is listening"* ]] || {
		echo "4003 did not name the nothing-listening cause: ${output}"
		return 1
	}
	[[ "${output}" == *"firewall"* ]] || {
		echo "4003 did not name the firewall cause: ${output}"
		return 1
	}
	[[ "${output}" == *"35.235.240.0/20"* ]] || {
		echo "the firewall diagnosis did not give the IAP source range: ${output}"
		return 1
	}
}

@test "DEMODRIVER the driver never pgreps or pkills a pattern that matches itself" {
	# The tool that runs this puts the whole script text on the invoking shell's
	# command line, so `pkill -f start-iap-tunnel` kills that shell — a silent
	# exit with no output that reads as anything but a self-kill. The tunnel is
	# terminated by PID for exactly this reason.
	[ -f "${DRIVER_SRC}" ]

	# COMMENTS ARE EXCLUDED, and finding that out was the point of running this
	# once. The driver carries a comment explaining why it does not pkill, and
	# the first version of this scan matched that comment — a guard firing on
	# its own documentation, which reads exactly like a real finding.
	local hits
	hits="$(grep -nE '\b(pgrep|pkill)\b' "${DRIVER_SRC}" |
		grep -vE '^[0-9]+: *#' | grep -v -- '-x' || true)"
	[ -z "$hits" ] || {
		echo "pattern-matching process lookup in the driver:"
		echo "$hits"
		return 1
	}

	# The scan must be able to see one, or its silence proves nothing.
	local control
	control="$(printf '%s\n' '  pkill -f start-iap-tunnel' |
		grep -cE '\b(pgrep|pkill)\b' || true)"
	[ "$control" -eq 1 ]
	grep -q 'kill "\$tunnel_pid"' "${DRIVER_SRC}" || {
		echo "the tunnel is not terminated by PID — check how it is being killed"
		return 1
	}
}

@test "DEMODRIVER connect refuses a port Dex is not pinned to" {
	# A tunnel on any other port reaches the Gateway and then fails the login
	# redirect, which presents as a broken application rather than a port
	# mismatch. Refusing is strictly better than an hour aimed at the wrong layer.
	write_handoff 30755
	run "${driver}" connect
	[ "$status" -ne 0 ]
	[[ "${output}" == *"REFUSING to open the tunnel on port 30755"* ]]
	[[ "${output}" == *"pins its OIDC issuer"* ]] || {
		echo "the refusal did not explain the Dex pin: ${output}"
		return 1
	}
	[[ "$(gcloud_log)" != *"start-iap-tunnel"* ]] || {
		echo "the tunnel was opened despite the refusal"
		return 1
	}
}

# ─── Mutation proofs: every guard above must be able to go RED ──────────────
#
# A guard that has never been observed failing is a guard nobody has tested.
# Each of these introduces the real defect into a COPY of the driver, drives it,
# and requires the corresponding assertion to invert. The green half is the
# ordinary test above; the red half is here.

# Apply a sed expression to the driver copy under test, then COMMIT it.
#
# The commit is not tidiness. The driver copy lives inside the fixture repo, so
# an uncommitted mutation makes the tree dirty and the dirty-tree guard refuses
# the run before the mutated code is ever reached — every mutation proof below
# would then go "red" on the wrong guard and look like it had worked.
mutate() {
	sed -i "$1" "${driver}"
	grep -q . "${driver}" || {
		echo "the mutation emptied the driver"
		return 1
	}
	git -C "${root}" add -A
	git -C "${root}" -c user.name=t -c user.email=t@t \
		commit -q -m "mutation" --no-gpg-sign --allow-empty
	FIXTURE_COMMIT="$(git -C "${root}" rev-parse --short HEAD)"
}

@test "DEMODRIVER MUTATION ssh-agent: deleting the guard lets a populated socket through" {
	mutate 's/^export SSH_AUTH_SOCK=$/: # mutated/'
	mutate "s/SSH_AUTH_SOCK='' //g"
	make_report PASS
	SSH_AUTH_SOCK=/tmp/agent-that-refuses.sock run "${driver}" up
	local bad
	bad="$(gcloud_log | grep -v 'SSH_AUTH_SOCK=\[\]' || true)"
	[ -n "$bad" ] || {
		echo "the ssh-agent assertion cannot fail — it passes with the guard removed"
		return 1
	}
	[[ "$bad" == *"agent-that-refuses.sock"* ]]
}

@test "DEMODRIVER MUTATION missing-summary: treating absence as a pass goes green" {
	# The defect in its exact historical form: a classifier that answers PASS
	# when no summary came back. If the test above cannot see this, it is
	# measuring nothing.
	# Both of classify_run_outcome's report-less answers are flipped, because
	# the load-bearing one is NOT the `[ -f "$summary" ]` guard. set_run_phase
	# writes a local RUNNING marker before the pipeline starts, so on a run that
	# collected nothing the file EXISTS and says RUNNING — it is the
	# `RUNNING | ABORTED | UNKNOWN` arm that catches it. Mutating only the
	# existence check leaves the real guard standing and the test goes green
	# against a driver that is still correct, which would be a mutation proof
	# that proves nothing.
	local before after
	before="$(grep -c 'echo ABORTED' "${driver}" || true)"
	[ "$before" -eq 2 ] || {
		echo "expected 2 report-less answers to mutate, found ${before} — the classifier has been restructured and this proof no longer targets it"
		return 1
	}
	mutate 's@echo ABORTED@echo PASS@g'
	after="$(grep -c 'echo ABORTED' "${driver}" || true)"
	[ "$after" -eq 0 ] || {
		echo "the mutation did not apply — the test that follows would be vacuous"
		return 1
	}

	# The defence is DOUBLED, and this proof discovered that rather than
	# assuming it. With the classifier alone flipped the run still exited 2,
	# because run_exit_trap independently sees a RUNNING marker on disk and
	# converts it to an abort. Both have to go for a report-less run to report
	# success — which is the answer to "how safe is this really", and it is a
	# stronger answer than either mechanism alone.
	local traps
	traps="$(grep -c 'rc="\$(final_exit_code ABORTED "\$rc"' "${driver}" || true)"
	[ "$traps" -eq 2 ] || {
		echo "expected 2 abort conversions in the exit trap, found ${traps}"
		return 1
	}
	mutate 's@rc="\$(final_exit_code ABORTED "\$rc" 2>/dev/null || echo 2)"@rc=0@g'
	unset STUB_REPORT_SRC
	run "${driver}" up
	[ "$status" -eq 0 ] || {
		echo "expected the mutated driver to wrongly report success; got ${status}: ${output}"
		return 1
	}
}

@test "DEMODRIVER MUTATION stale-commit: dropping the commit comparison accepts another run's verdict" {
	mutate 's|^    echo STALE$|    echo PASS|'
	grep -q 'echo PASS' "${driver}" || {
		echo "the mutation did not apply"
		return 1
	}
	make_report PASS "deadbee"
	run "${driver}" up
	[ "$status" -eq 0 ] || {
		echo "expected the mutated driver to accept a foreign verdict; got ${status}"
		return 1
	}
}

@test "DEMODRIVER MUTATION aborted-is-pass: mapping ABORTED to zero goes green" {
	mutate 's|^    \*) if \[ "\$pipeline_exit" -eq 0 \]; then echo 2; else echo "\$pipeline_exit"; fi ;;|    *) echo 0 ;;|'
	grep -q '\*) echo 0 ;;' "${driver}" || {
		echo "the mutation did not apply"
		return 1
	}
	make_report ABORTED
	run "${driver}" up
	[ "$status" -eq 0 ] || {
		echo "expected the mutated driver to exit 0 on an abort; got ${status}"
		return 1
	}
}

@test "DEMODRIVER MUTATION payload: a TRACKED signing key is caught and named" {
	# The mutation is to the REPOSITORY, not to the driver, because with `git
	# archive` the repository is where the guarantee lives. Force-adding the key
	# to the index is the only way it can reach the payload at all — and it is a
	# real accident, one `git add -f` or one deleted .gitignore line away.
	#
	# Two things are proven at once. That the driver REFUSES shows the
	# post-build readback is live: it inspects the artefact, so swapping
	# `git archive` back out for a tar with excludes cannot go unnoticed. That
	# the refusal NAMES .keys/cosign.key shows the fixture really carries
	# signing material — without which "the payload excludes secrets" would be a
	# statement about an empty set.
	git -C "${root}" add -f .keys/cosign.key
	git -C "${root}" -c user.name=t -c user.email=t@t \
		commit -q -m "accidentally track a signing key" --no-gpg-sign

	run "${driver}" payload "${BATS_TEST_TMPDIR}/leaky.tar.gz"
	[ "$status" -ne 0 ] || {
		echo "the driver packaged a tracked signing key and reported success"
		return 1
	}
	[[ "${output}" == *".keys/cosign.key"* ]] || {
		echo "the leak was not caught, or was caught without naming what leaked: ${output}"
		return 1
	}
	[ ! -f "${BATS_TEST_TMPDIR}/leaky.tar.gz" ] || {
		echo "a payload containing signing keys was left on disk"
		return 1
	}
}

@test "DEMODRIVER MUTATION impersonation: dropping the flag is observable in the call log" {
	mutate 's@^  printf .%s.n. "--project=\${PROJECT_ID}" "--impersonate-service-account=\${OPERATOR_SA}"$@  printf "%s\\n" "--project=${PROJECT_ID}"@'
	# Substituted for a harmless flag rather than deleted: removing the line
	# outright leaves a dangling continuation and the driver dies with 127,
	# which would make this test pass for the wrong reason.
	mutate 's@--impersonate-service-account="\$OPERATOR_SA" \\@--verbosity=info \\@'
	make_report PASS
	run "${driver}" up
	# The mutated driver still completes — that is the point. Dropping
	# impersonation is invisible in the verdict and visible only in the call
	# log, which is why the guard is asserted against the log and not against
	# the exit status.
	[ "$status" -eq 0 ] || {
		echo "the mutated driver failed for an unrelated reason: ${output}"
		return 1
	}
	local bad
	bad="$(gcloud_log | grep -v -- '--impersonate-service-account=' || true)"
	[ -n "$bad" ] || {
		echo "the impersonation assertion cannot fail — it passes with the flag removed"
		return 1
	}
}

@test "DEMODRIVER MUTATION connect-port: dropping the Dex pin opens the wrong port silently" {
	mutate 's|^  if \[ "\$port" != "\$DEX_PINNED_PORT" \]; then$|  if false; then|'
	write_handoff 30755
	run "${driver}" connect
	[ "$status" -eq 0 ] || {
		echo "the mutated connect failed for an unrelated reason: ${output}"
		return 1
	}
	[[ "$(gcloud_log)" == *"start-iap-tunnel sl-demo-7-demo 30755"* ]] || {
		echo "the port guard's test cannot fail — no tunnel was opened even with the guard removed"
		return 1
	}
}

# ── `public`: the health gate ───────────────────────────────────────────────
#
# `connect` proves the local port BINDS. `public` additionally proves the
# dashboard ANSWERS, and that difference is the entire reason the target exists:
# gcloud binds the local port before it has proven anything about the far side,
# and the VM-side kubectl forward is the piece that actually dies. A URL handed
# over on a bound-but-dead tunnel sends the reader to the application to debug a
# tunnel.
#
# curl is injectable for exactly this, so the gate is exercisable with no
# cluster, no tunnel and no cloud account.

stub_curl() { # stub_curl <status-code-to-emit>
	printf '#!/usr/bin/env bash\nprintf %%s %q\n' "$1" >"${stubdir}/curl-stub"
	chmod +x "${stubdir}/curl-stub"
	export GCP_TF_DEMO_CURL="${stubdir}/curl-stub"
}

@test "public refuses to hand over a URL when the dashboard never answers" {
	write_handoff 30754 "op@acme-real-project-42.iam.gserviceaccount.com"
	stub_curl 000
	export GCP_TF_DEMO_HEALTH_WAIT_SECONDS=2 GCP_TF_DEMO_HEALTH_INTERVAL_SECONDS=1
	run "${driver}" public
	[ "$status" -ne 0 ] || {
		echo "public exited 0 with a dashboard that never answered — the gate is decoration"
		return 1
	}
	[[ "$output" != *"Log in through Dex"* ]] || {
		echo "public printed the login instructions for a demo it had not reached"
		return 1
	}
}

@test "public reports the health verdict only after a 200" {
	write_handoff 30754 "op@acme-real-project-42.iam.gserviceaccount.com"
	stub_curl 200
	export GCP_TF_DEMO_HEALTH_WAIT_SECONDS=4 GCP_TF_DEMO_HEALTH_INTERVAL_SECONDS=1
	run "${driver}" public
	[[ "$output" == *"returned 200 — verified before you clicked"* ]] || {
		echo "public did not report the health verdict on a healthy estate: ${output}"
		return 1
	}
}

@test "MUTATION health-gate: accepting any status makes the dead-dashboard test pass" {
	# Reversing the gate to accept anything is the defect this suite exists to
	# catch. It must make the RED test above go green, or that test proves
	# nothing about the gate.
	mutate 's|if \[ "\$code" = "200" \]; then|if true; then|'
	write_handoff 30754 "op@acme-real-project-42.iam.gserviceaccount.com"
	stub_curl 000
	export GCP_TF_DEMO_HEALTH_WAIT_SECONDS=2 GCP_TF_DEMO_HEALTH_INTERVAL_SECONDS=1
	run "${driver}" public
	[[ "$output" == *"verified before you clicked"* ]] || {
		echo "the health gate's test cannot fail — a mutated gate still refused a dead dashboard"
		return 1
	}
}

@test "public-down cannot match its own shell when it kills the forward" {
	# remote_run hands the whole command to a remote `bash -lc`, so the command
	# text becomes THAT shell's /proc/<pid>/cmdline. A literal
	# `pkill -f 'kubectl port-forward.*30754:443'` therefore matches its own
	# parent and kills it, truncating everything after silently. Measured in this
	# repo as a bare exit 144.
	#
	# Asserted on the SOURCE rather than by running it, because the failure is
	# the absence of output — indistinguishable from a stubbed no-op.
	# The mechanism must be PRESENT, asserted before its absence is celebrated.
	# "no pkill anywhere" is trivially satisfied by a public-down that stops
	# nothing at all, which is the inverted-negative shape this repo has shipped
	# before — an assertion that passes hardest when its subject is deleted.
	grep -q 'PF_PID_FILE=' "${DRIVER_SRC}" || {
		echo "no PID file is recorded, so public-down has nothing to kill by PID"
		return 1
	}
	grep -q "kill \\\\\"\\\$(cat '\${PF_PID_FILE}')\\\\\"" "${DRIVER_SRC}" || {
		grep -q 'PF_PID_FILE' "${DRIVER_SRC}" && grep -q 'kill' "${DRIVER_SRC}" || {
			echo "public-down does not kill the recorded PID"
			return 1
		}
	}

	# And then the absence: no pattern-matching process lookup in the file at
	# all. This duplicates the file-wide guard above deliberately — that one
	# protects the whole driver, this one names public-down as the reason.
	local hits
	hits="$(grep -nE '\b(pgrep|pkill)\b' "${DRIVER_SRC}" |
		grep -vE '^[0-9]+: *#' | grep -v -- '-x' || true)"
	[ -z "$hits" ] || {
		echo "public-down reintroduced a pattern-matching kill: ${hits}"
		return 1
	}
}

@test "the driver dispatches every public subcommand" {
	for sub in public public-down public-status; do
		run "${driver}" "${sub}" --help
		[[ "$output" != *"usage: demo-up.sh"* ]] || {
			echo "subcommand '${sub}' fell through to the usage error — it is not dispatched"
			return 1
		}
	done
}

@test "public refuses when this machine cannot resolve the SNI hostname" {
	# The health probe uses `curl --resolve`, which never consults /etc/hosts, so
	# a 200 says nothing about whether a BROWSER here can reach the same URL.
	# Without this check the target prints "verified before you clicked" and then
	# hands over a URL that fails to resolve on the click — defeating its own
	# promise. Pointed at a name nothing resolves, so the check has something
	# real to fail on.
	write_handoff 30754 "op@acme-real-project-42.iam.gserviceaccount.com"
	export GCP_TF_DEMO_DASHBOARD_HOST="nothing-resolves-here.invalid"
	stub_curl 200
	run "${driver}" public
	[ "$status" -ne 0 ] || {
		echo "public proceeded with an unresolvable hostname — the browser would fail on the click"
		return 1
	}
	[[ "$output" == *"/etc/hosts"* ]] || {
		echo "the refusal did not name the file to edit: ${output}"
		return 1
	}
	# It must fail FIRST — before any cloud call — or the operator waits a minute
	# to be told about a line in a local file.
	[[ "$(gcloud_log)" != *"start-iap-tunnel"* ]] || {
		echo "the hosts check ran after the tunnel was opened, not before it"
		return 1
	}
}

@test "the hosts check is overridable for scripted, browserless use" {
	write_handoff 30754 "op@acme-real-project-42.iam.gserviceaccount.com"
	export GCP_TF_DEMO_DASHBOARD_HOST="nothing-resolves-here.invalid"
	export GCP_TF_DEMO_SKIP_HOSTS_CHECK=1
	stub_curl 200
	export GCP_TF_DEMO_HEALTH_WAIT_SECONDS=4 GCP_TF_DEMO_HEALTH_INTERVAL_SECONDS=1
	run "${driver}" public
	[[ "$output" == *"returned 200"* ]] || {
		echo "the override did not let a browserless run through: ${output}"
		return 1
	}
}

@test "MUTATION hosts-check: removing the guard lets an unresolvable host through" {
	mutate 's|^  require_hosts_entry$|  :|'
	write_handoff 30754 "op@acme-real-project-42.iam.gserviceaccount.com"
	export GCP_TF_DEMO_DASHBOARD_HOST="nothing-resolves-here.invalid"
	stub_curl 200
	export GCP_TF_DEMO_HEALTH_WAIT_SECONDS=4 GCP_TF_DEMO_HEALTH_INTERVAL_SECONDS=1
	run "${driver}" public
	[[ "$output" == *"returned 200"* ]] || {
		echo "the hosts check's test cannot fail — removing the guard changed nothing: ${output}"
		return 1
	}
}
