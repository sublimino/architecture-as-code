#!/usr/bin/env bats
#
# EAPCI-P1-1: demo-2 Kusari pilot profile verification.
#
# Asserts that:
#   1. demo-2 in deploy/gcp/sl-port-over-sandbox.example.tfvars has tailscale_hostname
#      matching ^sl-eap-[a-f0-9]{8}$ (= sl-eap-4b53ab6b) and hostname is empty.
#   2. demo-2 labels carry tier = "pilot".
#   3. Other lanes (demo-1, ci-1, ci-2) keep their default derived sl-<key> node names.
#   4. demo-up.sh ts_node_hostname prefers hand-off tailscale_hostname, falling back to sl-<key>.
#
# No GCP credentials, no live cluster. NOT fully offline: see setup_file below
# — `terraform console` validates every required_provider before it will
# evaluate even a pure-locals expression, so it needs the google/google-beta
# plugins installed, which (for these two modules, which carry no committed
# lock file — see .gitignore:153) means a real `terraform init` against
# registry.terraform.io. Same dependency the Makefile's own
# gcp_tf_init_offline documents for the gcp-tf-validate sweep.

setup_file() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export REPO_ROOT
	export TF_ENV_CONTRACT="${REPO_ROOT}/terraform/modules/env-contract"
	export TF_COMPUTE="${REPO_ROOT}/terraform/modules/compute"
	export EXAMPLE_TFVARS="${REPO_ROOT}/deploy/gcp/sl-port-over-sandbox.example.tfvars"
	export DRIVER_SRC="${REPO_ROOT}/scripts/gcp-tf/demo-up.sh"

	# Each module gets its own scratch TF_DATA_DIR under BATS_FILE_TMPDIR
	# rather than being `init`ed in place. terraform/modules/*/.terraform and
	# .terraform.lock.hcl are gitignored on purpose (modules are not roots;
	# only terraform/{,bootstrap,environments,platform} commit a lock file),
	# so running init straight in the repo's module directory would mutate a
	# tracked source tree with a multi-hundred-MB provider cache every run,
	# and would race any other test or agent working in the same checkout.
	# The scratch dir is torn down with BATS_FILE_TMPDIR when the file exits.
	export TF_DATA_DIR_ENV_CONTRACT="${BATS_FILE_TMPDIR}/tfdata-env-contract"
	export TF_DATA_DIR_COMPUTE="${BATS_FILE_TMPDIR}/tfdata-compute"

	local log="${BATS_FILE_TMPDIR}/tf-init.log"
	if ! TF_DATA_DIR="${TF_DATA_DIR_ENV_CONTRACT}" TF_CLI_CONFIG_FILE=/dev/null \
		terraform -chdir="${TF_ENV_CONTRACT}" init -backend=false -input=false -no-color >"${log}" 2>&1; then
		cat "${log}" >&2
		echo "SETUP FAILED: terraform init could not install hashicorp/google(-beta) for" >&2
		echo "  ${TF_ENV_CONTRACT}" >&2
		echo "This needs outbound network access to registry.terraform.io; it is the one" >&2
		echo "network dependency terraform console has, and nothing local works around it." >&2
		return 1
	fi
	if ! TF_DATA_DIR="${TF_DATA_DIR_COMPUTE}" TF_CLI_CONFIG_FILE=/dev/null \
		terraform -chdir="${TF_COMPUTE}" init -backend=false -input=false -no-color >"${log}" 2>&1; then
		cat "${log}" >&2
		echo "SETUP FAILED: terraform init could not install hashicorp/google(-beta) for" >&2
		echo "  ${TF_COMPUTE}" >&2
		echo "This needs outbound network access to registry.terraform.io; it is the one" >&2
		echo "network dependency terraform console has, and nothing local works around it." >&2
		return 1
	fi
}

setup() {
	[ -f "${EXAMPLE_TFVARS}" ]
	[ -f "${DRIVER_SRC}" ]
	[ -d "${TF_ENV_CONTRACT}" ]
}

@test "demo-2 example profile declares tailscale_hostname matching ^sl-eap-[a-f0-9]{8}$" {
	val="$(printf 'local.resolved["demo-2"].tailscale_hostname\n' | TF_DATA_DIR="${TF_DATA_DIR_ENV_CONTRACT}" TF_CLI_CONFIG_FILE=/dev/null terraform -chdir="${TF_ENV_CONTRACT}" console -var-file="${EXAMPLE_TFVARS}" | tail -n 1 | tr -d '"')"
	[ "${val}" = "sl-eap-4b53ab6b" ]
	[[ "${val}" =~ ^sl-eap-[a-f0-9]{8}$ ]]
}

@test "demo-2 example profile has empty hostname (public TLS edge disabled)" {
	val="$(printf 'local.resolved["demo-2"].hostname\n' | TF_DATA_DIR="${TF_DATA_DIR_ENV_CONTRACT}" TF_CLI_CONFIG_FILE=/dev/null terraform -chdir="${TF_ENV_CONTRACT}" console -var-file="${EXAMPLE_TFVARS}" | tail -n 1 | tr -d '"')"
	[ "${val}" = "" ]
}

@test "demo-2 example profile carries labels.tier = pilot" {
	val="$(printf 'local.resolved["demo-2"].labels["tier"]\n' | TF_DATA_DIR="${TF_DATA_DIR_ENV_CONTRACT}" TF_CLI_CONFIG_FILE=/dev/null terraform -chdir="${TF_ENV_CONTRACT}" console -var-file="${EXAMPLE_TFVARS}" | tail -n 1 | tr -d '"')"
	[ "${val}" = "pilot" ]
}

@test "other lanes without tailscale_hostname derive default sl-<key> node names" {
	val="$(printf 'local.resolved["demo-1"].tailscale_hostname\n' | TF_DATA_DIR="${TF_DATA_DIR_ENV_CONTRACT}" TF_CLI_CONFIG_FILE=/dev/null terraform -chdir="${TF_ENV_CONTRACT}" console -var-file="${EXAMPLE_TFVARS}" | tail -n 1 | tr -d '"')"
	[ "${val}" = "" ]

	eval_comp="$(printf 'coalesce(var.tailscale_hostname, "sl-${var.environment_key}")\n' | TF_VAR_environment_key="demo-1" TF_VAR_tailscale_hostname="" TF_DATA_DIR="${TF_DATA_DIR_COMPUTE}" TF_CLI_CONFIG_FILE=/dev/null terraform -chdir="${TF_COMPUTE}" console | tail -n 1 | tr -d '"')"
	[ "${eval_comp}" = "sl-demo-1" ]

	eval_ci="$(printf 'coalesce(var.tailscale_hostname, "sl-${var.environment_key}")\n' | TF_VAR_environment_key="ci-1" TF_VAR_tailscale_hostname="" TF_DATA_DIR="${TF_DATA_DIR_COMPUTE}" TF_CLI_CONFIG_FILE=/dev/null terraform -chdir="${TF_COMPUTE}" console | tail -n 1 | tr -d '"')"
	[ "${eval_ci}" = "sl-ci-1" ]
}

@test "ts_node_hostname in demo-up.sh honours hand-off tailscale_hostname" {
	local handoff="${BATS_TEST_TMPDIR}/demo-2.handoff.json"
	printf '{"tailscale_hostname": "sl-eap-4b53ab6b"}\n' > "${handoff}"
	run bash -c 'eval "$(sed -n "/^ts_node_hostname() {/,/^}/p" "'"${DRIVER_SRC}"'")" && HANDOFF_FILE="'"${handoff}"'" ENV_KEY="demo-2" ts_node_hostname'
	[ "$status" -eq 0 ]
	[ "$output" = "sl-eap-4b53ab6b" ]
}

@test "ts_node_hostname in demo-up.sh falls back to sl-<key> when tailscale_hostname is absent" {
	local handoff="${BATS_TEST_TMPDIR}/demo-1.handoff.json"
	printf '{"hostname": ""}\n' > "${handoff}"
	run bash -c 'eval "$(sed -n "/^ts_node_hostname() {/,/^}/p" "'"${DRIVER_SRC}"'")" && HANDOFF_FILE="'"${handoff}"'" ENV_KEY="demo-1" ts_node_hostname'
	[ "$status" -eq 0 ]
	[ "$output" = "sl-demo-1" ]
}
