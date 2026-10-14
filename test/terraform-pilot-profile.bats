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
# Offline: no GCP credentials, no network, no live cluster.

setup_file() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export REPO_ROOT
	export TF_ENV_CONTRACT="${REPO_ROOT}/terraform/modules/env-contract"
	export EXAMPLE_TFVARS="${REPO_ROOT}/deploy/gcp/sl-port-over-sandbox.example.tfvars"
	export DRIVER_SRC="${REPO_ROOT}/scripts/gcp-tf/demo-up.sh"
}

setup() {
	[ -f "${EXAMPLE_TFVARS}" ]
	[ -f "${DRIVER_SRC}" ]
	[ -d "${TF_ENV_CONTRACT}" ]
}

@test "demo-2 example profile declares tailscale_hostname matching ^sl-eap-[a-f0-9]{8}$" {
	val="$(printf 'local.resolved["demo-2"].tailscale_hostname\n' | TF_CLI_CONFIG_FILE=/dev/null terraform -chdir="${TF_ENV_CONTRACT}" console -var-file="${EXAMPLE_TFVARS}" | tail -n 1 | tr -d '"')"
	[ "${val}" = "sl-eap-4b53ab6b" ]
	[[ "${val}" =~ ^sl-eap-[a-f0-9]{8}$ ]]
}

@test "demo-2 example profile has empty hostname (public TLS edge disabled)" {
	val="$(printf 'local.resolved["demo-2"].hostname\n' | TF_CLI_CONFIG_FILE=/dev/null terraform -chdir="${TF_ENV_CONTRACT}" console -var-file="${EXAMPLE_TFVARS}" | tail -n 1 | tr -d '"')"
	[ "${val}" = "" ]
}

@test "demo-2 example profile carries labels.tier = pilot" {
	val="$(printf 'local.resolved["demo-2"].labels["tier"]\n' | TF_CLI_CONFIG_FILE=/dev/null terraform -chdir="${TF_ENV_CONTRACT}" console -var-file="${EXAMPLE_TFVARS}" | tail -n 1 | tr -d '"')"
	[ "${val}" = "pilot" ]
}

@test "other lanes without tailscale_hostname derive default sl-<key> node names" {
	val="$(printf 'local.resolved["demo-1"].tailscale_hostname\n' | TF_CLI_CONFIG_FILE=/dev/null terraform -chdir="${TF_ENV_CONTRACT}" console -var-file="${EXAMPLE_TFVARS}" | tail -n 1 | tr -d '"')"
	[ "${val}" = "" ]

	eval_comp="$(printf 'coalesce(var.tailscale_hostname, "sl-${var.environment_key}")\n' | TF_VAR_environment_key="demo-1" TF_VAR_tailscale_hostname="" TF_CLI_CONFIG_FILE=/dev/null terraform -chdir="${REPO_ROOT}/terraform/modules/compute" console | tail -n 1 | tr -d '"')"
	[ "${eval_comp}" = "sl-demo-1" ]

	eval_ci="$(printf 'coalesce(var.tailscale_hostname, "sl-${var.environment_key}")\n' | TF_VAR_environment_key="ci-1" TF_VAR_tailscale_hostname="" TF_CLI_CONFIG_FILE=/dev/null terraform -chdir="${REPO_ROOT}/terraform/modules/compute" console | tail -n 1 | tr -d '"')"
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
