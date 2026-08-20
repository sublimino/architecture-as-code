#!/usr/bin/env bats
#
# Serving the tailnet URL is a BOOT property of the lane, not an operator's
# memory.
#
# ─── The defect this suite exists for ───────────────────────────────────────
#
# `tailscale serve` was configured in exactly one place: an operator typing
# `make gcp-tf-ts-up ENV=<key>`. No boot path, no pipeline and no Terraform ever
# called it for any lane.
#
# Measured on 2026-08-20 against the live estate: sl-ci-1 and sl-ci-2 were on
# the tailnet, online, correctly tagged `tag:sl-demo`, correctly named, and each
# running a complete and healthy Signal Loom estate — and answering nothing.
# `sudo tailscale serve status` said `No serve config`. sl-demo-1 answered 200
# solely because a human had run the command on it. `ts-up ENV=ci-1` took
# sl-ci-1 from 000 to 200 against COMPLETELY UNCHANGED CODE: there was nothing
# wrong with the path, only an invocation that never happened.
#
# ─── Why the boot path, and not just the driver ─────────────────────────────
#
# install_tailscale_logout_unit runs `tailscale logout` on every clean shutdown
# so the next build can reclaim the MagicDNS name. A logout WIPES the serve
# config. A stop/start — which is what a machine-type change is — therefore
# takes a serving node and returns it online, correctly named, resolving through
# MagicDNS, and serving nothing, with every cheap health check reporting
# healthy. A destroy/recreate loses it too, because the disk goes with it.
#
# Only the startup script survives both, so that is where the unit is declared.
#
# ─── Two copies, and the seam that holds them together ──────────────────────
#
# scripts/gcp-tf/demo-up.sh installs a compatible unit at RUNTIME, for VMs built
# before this existed. That is two definitions of one unit, which this repo
# rightly distrusts. It is structurally forced: the startup script runs before
# any code is delivered to the VM, so it cannot source anything from the repo.
# The SEAM tests at the bottom assert the two files still agree on every
# load-bearing name, and fail loudly when they drift.
#
# ─── Named terraform-*.bats deliberately ────────────────────────────────────
#
# `make gcp-tf-validate` runs `$(wildcard test/terraform-*.bats)`, so this suite
# is registered the moment it lands and cannot be forgotten by a hand-maintained
# list — the failure mode that left 33 suites in this repo passing and unasked.
#
# Everything runs offline. No tailnet, no cloud, no credentials, no network.

setup_file() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export REPO_ROOT
	export STARTUP="${REPO_ROOT}/terraform/modules/compute/startup/demo-vm.sh"
	export DRIVER_SRC="${REPO_ROOT}/scripts/gcp-tf/demo-up.sh"
	export COMPUTE_TF="${REPO_ROOT}/terraform/modules/compute/main.tf"
	export HELPER="${REPO_ROOT}/test/helpers/ts-serve-unit.bash"
}

setup() {
	# Presence before behaviour, always. A suite driving a file that was never
	# written reports whatever the shell does with a missing path.
	[ -f "${STARTUP}" ]
	[ -f "${DRIVER_SRC}" ]
	[ -f "${COMPUTE_TF}" ]
	[ -f "${HELPER}" ]

	# ─── The MECHANISM must be present before its behaviour is asserted ─────
	#
	# Without these, a tree that had never received this work would sail
	# through: the extraction would produce nothing, every call would fail with
	# "command not found", and a `[ "$status" -ne 0 ]` somewhere would hold.
	grep -q '^install_tailscale_serve_unit()' "${STARTUP}" || {
		echo "the startup script has no install_tailscale_serve_unit — this suite would test nothing"
		return 1
	}

	# ─── DEAD CODE IS THE FAILURE MODE THIS ONE CATCHES ─────────────────────
	#
	# A perfectly correct installer that nothing calls installs nothing. Every
	# other test in this file would still pass, because they all invoke the
	# function directly. This is the only assertion that the boot path actually
	# reaches it.
	grep -q '^  install_tailscale_serve_unit$' "${STARTUP}" || {
		echo "install_tailscale_serve_unit is never CALLED by bring_tailscale_up — it is dead code and no lane would serve"
		return 1
	}

	# shellcheck source=test/helpers/ts-serve-unit.bash
	source "${HELPER}"

	stubdir="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "${stubdir}"
	ts_serve_stub_systemctl "${stubdir}"
	export PATH="${stubdir}:${PATH}"

	export TS_SERVE_UNIT="${BATS_TEST_TMPDIR}/serve.service"
	export TS_SERVE_HELPER="${BATS_TEST_TMPDIR}/serve-helper"
	export STUB_SYSTEMCTL_LOG="${BATS_TEST_TMPDIR}/systemctl.log"
	: >"${STUB_SYSTEMCTL_LOG}"

	unset STUB_APP_PORT STUB_SYSTEMCTL_RC

	harness="${BATS_TEST_TMPDIR}/harness.bash"
	ts_serve_harness "${harness}" "${STARTUP}"
}

# Run the extracted installer with a given app-port metadata answer.
# `run_installer` with no argument models the attribute being ABSENT.
run_installer() {
	if [ "$#" -gt 0 ]; then
		STUB_APP_PORT="$1" run bash -c "source '${harness}'; install_tailscale_serve_unit"
	else
		run bash -c "source '${harness}'; install_tailscale_serve_unit"
	fi
}

systemctl_log() { cat "${STUB_SYSTEMCTL_LOG}" 2>/dev/null || true; }

# ─────────────────────────────────────────────────────────────────────────────
#  The happy path
# ─────────────────────────────────────────────────────────────────────────────

@test "BOOT the serve unit and its helper are both written" {
	run_installer 30754
	[ "$status" -eq 0 ] || {
		echo "installer failed: ${output}"
		return 1
	}
	[ -f "${TS_SERVE_HELPER}" ] || {
		echo "no helper written"
		return 1
	}
	[ -x "${TS_SERVE_HELPER}" ] || {
		echo "the helper is not executable — systemd would fail to run it"
		return 1
	}
	[ -f "${TS_SERVE_UNIT}" ] || {
		echo "no unit written"
		return 1
	}
}

@test "BOOT the helper proxies to the port that metadata published" {
	# The whole reason signalloom-app-port exists. A hardcoded port would pass a
	# test that asserted a constant, and would be silently wrong for every lane
	# whose app_port differs.
	run_installer 31999
	grep -q "http://127.0.0.1:31999" "${TS_SERVE_HELPER}" || {
		echo "the helper does not proxy to the published port:"
		cat "${TS_SERVE_HELPER}"
		return 1
	}
	# ... and specifically NOT to some other lane's port.
	grep -q "30754" "${TS_SERVE_HELPER}" && {
		echo "the helper carries a hardcoded port instead of the published one:"
		cat "${TS_SERVE_HELPER}"
		return 1
	}
	return 0
}

@test "BOOT the helper serves, and never funnels" {
	# A boot unit that re-asserted funnel would republish this estate to the
	# public internet after every reboot, on the strength of one funnel-up
	# somebody ran months earlier. This is a security assertion.
	run_installer 30754
	grep -q "serve --bg" "${TS_SERVE_HELPER}" || {
		echo "the helper does not configure serve:"
		cat "${TS_SERVE_HELPER}"
		return 1
	}
	grep -q "funnel" "${TS_SERVE_HELPER}" && {
		echo "the helper mentions funnel — public exposure must never be automatic:"
		cat "${TS_SERVE_HELPER}"
		return 1
	}
	grep -q "funnel" "${TS_SERVE_UNIT}" && {
		echo "the unit mentions funnel — public exposure must never be automatic:"
		cat "${TS_SERVE_UNIT}"
		return 1
	}
	return 0
}

@test "BOOT the helper waits for tailscaled instead of failing instantly" {
	# `tailscale serve` against a tailscaled that is running but not yet
	# AUTHENTICATED fails immediately. A oneshot with no retry would leave the
	# unit failed and the URL dead for the whole uptime of the machine.
	run_installer 30754
	grep -q "BackendState" "${TS_SERVE_HELPER}" || {
		echo "the helper does not wait for the daemon to authenticate:"
		cat "${TS_SERVE_HELPER}"
		return 1
	}
}

@test "BOOT the unit runs the helper and is linked into multi-user.target" {
	run_installer 30754
	grep -q "^ExecStart=${TS_SERVE_HELPER}$" "${TS_SERVE_UNIT}" || {
		echo "the unit's ExecStart does not point at the helper:"
		cat "${TS_SERVE_UNIT}"
		return 1
	}
	grep -q "^WantedBy=multi-user.target$" "${TS_SERVE_UNIT}" || {
		echo "the unit is not linked into multi-user.target — it would never run at boot:"
		cat "${TS_SERVE_UNIT}"
		return 1
	}
	grep -q "^After=.*tailscaled.service" "${TS_SERVE_UNIT}" || {
		echo "the unit is not ordered after tailscaled:"
		cat "${TS_SERVE_UNIT}"
		return 1
	}
}

@test "BOOT the unit is both enabled AND started" {
	# Two different bugs, and a stub that collapsed them could not tell them
	# apart. `enable` alone arms the NEXT boot, leaving the boot that just built
	# the lane serving nothing. `start` alone serves now and never again.
	run_installer 30754
	systemctl_log | grep -q "^enable signalloom-tailscale-serve.service$" || {
		echo "the unit was never enabled — serving would not survive a reboot:"
		systemctl_log
		return 1
	}
	systemctl_log | grep -q "^start signalloom-tailscale-serve.service$" || {
		echo "the unit was never started — the lane that just booted serves nothing:"
		systemctl_log
		return 1
	}
}

# ─────────────────────────────────────────────────────────────────────────────
#  Refusals — an absent port must not become a wrong one
# ─────────────────────────────────────────────────────────────────────────────

@test "BOOT an ABSENT app-port writes no unit and says the node will not serve" {
	run_installer
	# Never fatal: this file's convention is that a missing optional feature
	# degrades the VM, it does not fail the bootstrap.
	[ "$status" -eq 0 ] || {
		echo "a missing port aborted the whole bootstrap: ${output}"
		return 1
	}
	[ ! -f "${TS_SERVE_UNIT}" ] || {
		echo "a unit was written despite there being no port to serve"
		return 1
	}
	[[ "$output" == *"SERVING NOTHING"* ]] || {
		echo "the warning does not say what the consequence is: ${output}"
		return 1
	}
}

@test "BOOT a NON-NUMERIC app-port is refused rather than interpolated" {
	# The failure this prevents is a real TLS listener in front of nothing,
	# which is more confusing than no listener at all.
	local bad
	for bad in "" "8080abc" "not-a-port" "80 80"; do
		rm -f "${TS_SERVE_UNIT}" "${TS_SERVE_HELPER}"
		run_installer "${bad}"
		[ "$status" -eq 0 ] || {
			echo "port '${bad}' aborted the bootstrap: ${output}"
			return 1
		}
		[ ! -f "${TS_SERVE_UNIT}" ] || {
			echo "port '${bad}' was accepted and a unit was written"
			return 1
		}
	done
}

@test "BOOT a failed enable degrades loudly and never aborts the bootstrap" {
	STUB_SYSTEMCTL_RC=1 STUB_APP_PORT=30754 run bash -c "source '${harness}'; install_tailscale_serve_unit"
	[ "$status" -eq 0 ] || {
		echo "a systemd failure took the whole VM bootstrap down: ${output}"
		return 1
	}
	[[ "$output" == *"WARNING"* ]] || {
		echo "the failure was silent: ${output}"
		return 1
	}
}

# ─────────────────────────────────────────────────────────────────────────────
#  Terraform publishes the port the startup script reads
# ─────────────────────────────────────────────────────────────────────────────

@test "TF signalloom-app-port is published as instance metadata" {
	grep -q 'signalloom-app-port' "${COMPUTE_TF}" || {
		echo "modules/compute never publishes signalloom-app-port — the startup script would find nothing and no lane would serve"
		return 1
	}
	# From the VARIABLE, not a literal. A hardcoded port in the metadata block
	# is the same defect as a hardcoded port in bash, one layer up.
	grep -qE 'signalloom-app-port[[:space:]]*=[[:space:]]*tostring\(var\.app_port\)' "${COMPUTE_TF}" || {
		echo "signalloom-app-port is not derived from var.app_port:"
		grep -n 'signalloom-app-port' "${COMPUTE_TF}"
		return 1
	}
}

@test "TF the port metadata rides with the tailscale block, not the base block" {
	# A non-Tailscale instance's metadata must stay byte-identical to what it
	# was, which is the stated contract of the surrounding local.
	#
	# Matched on the ASSIGNMENT, not on any mention of the name. A `grep
	# 'signalloom-app-port'` also hits the comment block that explains why the
	# key exists — which sits above the local, so the first match was prose and
	# the test failed against correct code. Parsing a comment as data is a shape
	# this repo has been caught by twice.
	local line tail_line
	line="$(grep -nE '^[[:space:]]*signalloom-app-port[[:space:]]*=' "${COMPUTE_TF}" | head -n1 | cut -d: -f1)"
	tail_line="$(grep -n 'tailscale_metadata = var.tailscale_enabled' "${COMPUTE_TF}" | head -n1 | cut -d: -f1)"
	[ -n "$line" ] && [ -n "$tail_line" ] && [ "$line" -gt "$tail_line" ] || {
		echo "signalloom-app-port is not inside the tailscale_metadata block (port at line ${line:-?}, block at ${tail_line:-?})"
		return 1
	}
}

# ─────────────────────────────────────────────────────────────────────────────
#  SEAM — the boot copy and the runtime copy must not drift
#
#  Two definitions of one unit is a shape this repo distrusts, and rightly. It
#  is structurally forced here: the startup script runs before any code reaches
#  the VM, so it cannot source the driver. These assertions are what make the
#  duplication safe rather than merely tolerated.
# ─────────────────────────────────────────────────────────────────────────────

@test "SEAM both copies agree on the unit name" {
	grep -q 'signalloom-tailscale-serve.service' "${STARTUP}" || {
		echo "the startup script does not name the unit"
		return 1
	}
	grep -q 'signalloom-tailscale-serve' "${DRIVER_SRC}" || {
		echo "the driver does not name the unit — ts-status could not report on what the boot path installs"
		return 1
	}
}

@test "SEAM both copies agree on the helper path" {
	# The driver COMPOSES its path from the unit name
	# (`/usr/local/sbin/${TS_SERVE_UNIT}`) while the startup script states a
	# literal, so a plain grep for the literal fails against two files that
	# actually agree. Resolving the driver's expression is the difference
	# between a test that measures the seam and one that measures spelling.
	local boot_path driver_unit driver_tmpl driver_path
	boot_path="$(sed -n 's/^readonly TS_SERVE_HELPER="\([^"]*\)".*/\1/p' "${STARTUP}" | head -n1)"
	driver_unit="$(sed -n 's/^TS_SERVE_UNIT="\${GCP_TF_DEMO_TS_SERVE_UNIT:-\([^}]*\)}".*/\1/p' "${DRIVER_SRC}" | head -n1)"
	driver_tmpl="$(sed -n 's/^TS_SERVE_HELPER_PATH="\(.*\)"$/\1/p' "${DRIVER_SRC}" | head -n1)"

	[ -n "$boot_path" ] || {
		echo "could not read TS_SERVE_HELPER from the startup script"
		return 1
	}
	[ -n "$driver_unit" ] || {
		echo "could not read TS_SERVE_UNIT's default from the driver"
		return 1
	}
	[ -n "$driver_tmpl" ] || {
		echo "could not read TS_SERVE_HELPER_PATH from the driver"
		return 1
	}

	driver_path="${driver_tmpl/\$\{TS_SERVE_UNIT\}/${driver_unit}}"

	[ "$boot_path" = "$driver_path" ] || {
		echo "the two copies install the helper in different places:"
		echo "  boot:   ${boot_path}"
		echo "  driver: ${driver_path}"
		echo "A VM could end up with both, and the stale one would win at boot."
		return 1
	}
}

@test "SEAM both copies serve the same HTTPS port" {
	local boot_port driver_port
	boot_port="$(sed -n 's/^readonly TS_SERVE_HTTPS_PORT="\([0-9]*\)".*/\1/p' "${STARTUP}" | head -n1)"
	driver_port="$(sed -n 's/^TS_SERVE_PORT="\${GCP_TF_DEMO_TS_SERVE_PORT:-\([0-9]*\)}".*/\1/p' "${DRIVER_SRC}" | head -n1)"
	[ -n "$boot_port" ] || {
		echo "could not read the boot copy's HTTPS port"
		return 1
	}
	[ -n "$driver_port" ] || {
		echo "could not read the driver's HTTPS port"
		return 1
	}
	[ "$boot_port" = "$driver_port" ] || {
		echo "the two copies serve different ports: boot=${boot_port} driver=${driver_port}"
		return 1
	}
}

@test "SEAM ts-status reads the unit the boot path installs" {
	# The detector has to be asking about the thing the boot path creates. If
	# these drift, ts-status reports 'not-found' on a perfectly serving node and
	# becomes the line everyone learns to ignore.
	grep -q 'systemctl is-enabled' "${DRIVER_SRC}" || {
		echo "the driver never asks whether the unit is enabled"
		return 1
	}
	# ANCHORED on the definition, and separately on a call site.
	#
	# A bare `grep ts_serve_unit_state` is satisfied by ANY name containing it —
	# `ts_serve_unit_state_RENAMED` matches perfectly — so renaming the function
	# out from under ts-status left this green. Caught by M13 in
	# test/tailscale-serve-boot-mutation-proof.sh, which is what that harness is
	# for. Requiring both halves also means a defined-but-never-called reader
	# cannot satisfy it.
	grep -qE '^ts_serve_unit_state\(\) \{' "${DRIVER_SRC}" || {
		echo "the driver has no ts_serve_unit_state() definition — ts-status cannot report on the boot unit"
		return 1
	}
	grep -qE '^[[:space:]]+[a-z_]+="\$\(ts_serve_unit_state\)"' "${DRIVER_SRC}" || {
		echo "ts_serve_unit_state() is defined but never called — ts-status would report nothing about durability"
		return 1
	}
}

# ─────────────────────────────────────────────────────────────────────────────
#  BLAST RADIUS — editing the startup script replaces every lane VM
#
#  `metadata_startup_script` is ForceNew in the google provider, so any change
#  to demo-vm.sh makes the next apply DESTROY and recreate that instance: new
#  boot disk, new tailnet IP, estate gone, ~40 minutes to rebuild. Four lanes,
#  four replacements.
#
#  This is the single most expensive property of that file and it is invisible
#  from inside it. These tests exist so the next person meets it before their
#  one-word edit does.
# ─────────────────────────────────────────────────────────────────────────────

@test "BLAST the startup script states that editing it replaces the VM" {
	# A documentation assertion, and named as one rather than dressed up as a
	# behavioural check. The ForceNew semantics belong to the provider — no test
	# in this repo can exercise them without a real apply. What CAN be pinned is
	# that the warning is present and says what the consequence is, which is the
	# part that keeps getting deleted in a tidy-up.
	grep -q 'ForceNew' "${STARTUP}" || {
		echo "the startup script does not mention ForceNew — the next editor has no warning that a one-word change rebuilds the fleet"
		return 1
	}
	grep -qiE 'destroys and recreates|REPLACES that instance' "${STARTUP}" || {
		echo "the warning does not state the CONSEQUENCE, only the mechanism. 'ForceNew' means nothing to someone who has not hit it."
		return 1
	}
}

@test "BLAST the script is delivered by metadata_startup_script, not the metadata map" {
	# THE BEHAVIOURAL HALF, and the reason this pair is not just a comment check.
	#
	# `metadata_startup_script` is ForceNew; an ordinary `metadata` map entry
	# named startup-script is NOT. The two are interchangeable to GCE and have
	# opposite replacement semantics in Terraform, so which one is used is a real
	# and checkable fact about this module — and moving between them silently
	# changes whether an edit rebuilds the fleet or updates it in place.
	grep -qE '^[[:space:]]*metadata_startup_script[[:space:]]*=' "${COMPUTE_TF}" || {
		echo "modules/compute no longer delivers the script via metadata_startup_script — the documented ForceNew blast radius may no longer be accurate"
		return 1
	}
	# And the inverse: a startup-script key smuggled into the metadata map would
	# mean two scripts race, and the documented semantics would be wrong.
	grep -qE '^[[:space:]]*startup-script[[:space:]]*=' "${COMPUTE_TF}" && {
		echo "a 'startup-script' metadata key exists alongside metadata_startup_script — two delivery paths, and only one of them is documented"
		return 1
	}
	return 0
}

@test "BLAST values the script READS are metadata, not baked into the script" {
	# The practical consequence of the blast radius, asserted rather than merely
	# advised: a per-environment value must be a metadata key, because metadata
	# updates in place while the script does not. signalloom-app-port is the
	# worked example — baking the port into the script would have made every
	# port change a four-VM rebuild.
	grep -q 'metadata_attr signalloom-app-port' "${STARTUP}" || {
		echo "the port is not read from metadata — a port change would require rebuilding every lane"
		return 1
	}
}
