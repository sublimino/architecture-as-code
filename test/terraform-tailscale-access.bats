#!/usr/bin/env bats
#
# The Tailscale access path: the Make targets and the driver subcommands that
# make Tailscale the PRIMARY way into the Signal Loom demo, with IAP kept as the
# documented fallback.
#
# Named `terraform-*.bats` deliberately. `make gcp-tf-validate` runs
# `$(wildcard test/terraform-*.bats)`, so this suite is registered the moment it
# lands and cannot be forgotten by a hand-maintained list — the failure mode
# that left 33 suites in this repo passing and unasked.
#
# Everything runs against stubs on PATH: a fake `tailscale`, a fake `gcloud`, a
# fake `getent` and a fake dex-origin library. No tailnet, no cloud, no network,
# no credentials. That is not a convenience — the four things this suite is
# really about (a node that is offline, a name that does not resolve, a
# dashboard that never answers, an origin somebody else is holding) are all
# states you cannot reliably produce on a healthy estate.
#
# Two halves:
#
#   The Make contract  — targets EXECUTED, not grepped, and asserted on what
#                        they refuse and what they forward. Grepping a recipe
#                        passes hardest when the target has been DELETED.
#   The driver         — scripts/gcp-tf/demo-up.sh's ts-*/funnel-* subcommands
#                        run end to end.
#
# The MUTATION tests at the bottom are the point of the file. Each one breaks
# the real guard in the copy under test and asserts that the corresponding
# assertion above goes green — because a guard whose test cannot fail is
# decoration, and this repo has shipped that shape more than once.

setup_file() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export REPO_ROOT
	export MAKEFILE="${REPO_ROOT}/Makefile"
	export DRIVER_SRC="${REPO_ROOT}/scripts/gcp-tf/demo-up.sh"
	export FIXTURES="${REPO_ROOT}/test/fixtures/gcp-tf-tailscale"
}

# Every target this suite owns, written once so a target added to the family
# cannot be added to half the assertions.
TS_TARGETS="gcp-tf-ts-status gcp-tf-ts-up gcp-tf-funnel-up gcp-tf-funnel-down"

# The IAP family, asserted here as a REGRESSION set. "Tailscale becomes
# primary" is a statement about which path leads in the docs and in the
# recommended flow, not a licence to delete the tested one. If this list stops
# passing, this chunk broke the fallback.
IAP_TARGETS="gcp-tf-connect gcp-tf-public gcp-tf-public-down gcp-tf-public-status"

setup() {
	# Presence before behaviour, always. A suite driving a script that was never
	# written reports whatever the shell does with a missing file, and a suite
	# driving a script with no Tailscale code in it reports a clean green.
	[ -f "${MAKEFILE}" ]
	[ -f "${DRIVER_SRC}" ]
	[ -x "${DRIVER_SRC}" ]
	[ -d "${FIXTURES}" ]

	# The mechanism must be PRESENT before its behaviour is asserted. Without
	# this, every `run "${driver}" ts-up` below would fall through to the usage
	# error, `[ "$status" -ne 0 ]` would hold, and the suite would report that
	# four refusals work correctly against a driver that has no Tailscale path
	# at all.
	grep -q '^cmd_ts_up()' "${DRIVER_SRC}" || {
		echo "the driver has no cmd_ts_up — this suite would test nothing"
		return 1
	}
	grep -q '^  ts-up) cmd_ts_up ;;' "${DRIVER_SRC}" || {
		echo "ts-up is not dispatched — every subcommand test would hit the usage error"
		return 1
	}

	ENV_KEY="demo-7"
	TS_HOST="sl-${ENV_KEY}"
	TS_FQDN="${TS_HOST}.example-tailnet.ts.net"

	root="${BATS_TEST_TMPDIR}/repo"
	stubdir="${BATS_TEST_TMPDIR}/bin"
	log="${BATS_TEST_TMPDIR}/gcloud.log"
	tslog="${BATS_TEST_TMPDIR}/tailscale.log"
	dexlog="${BATS_TEST_TMPDIR}/dex.log"
	ts_json="${BATS_TEST_TMPDIR}/ts-status.json"
	driver="${root}/scripts/gcp-tf/demo-up.sh"

	mkdir -p "${stubdir}" "${root}/scripts/gcp-tf" "${root}/deploy/gcp"
	cp "${DRIVER_SRC}" "${driver}"
	chmod +x "${driver}"

	# `getent` is stubbed on PATH rather than injected, because magicdns_resolves
	# asks the name-service switch directly — which is correct, and is exactly
	# why the answer cannot be handed to it in a variable.
	for s in gcloud tailscale getent; do
		cp "${FIXTURES}/stub-${s}" "${stubdir}/${s}"
		chmod +x "${stubdir}/${s}"
	done
	cp "${FIXTURES}/stub-dex-origin" "${stubdir}/dex-origin"
	chmod +x "${stubdir}/dex-origin"

	: >"${log}"
	: >"${tslog}"
	: >"${dexlog}"

	write_handoff
	write_ts_status "${TS_HOST}" true

	export PATH="${stubdir}:${PATH}"
	export STUB_GCLOUD_LOG="${log}"
	export STUB_TS_LOG="${tslog}"
	export STUB_DEX_LOG="${dexlog}"
	export STUB_TS_STATUS_JSON="${ts_json}"

	export GCP_TF_DEMO_REPO_ROOT="${root}"
	export GCP_TF_DEMO_ENV="${ENV_KEY}"
	export GCP_TF_HANDOFF_DIR="${root}/deploy/gcp"
	export GCP_TF_DEMO_REPORT_DIR="${root}/demo-reports"

	# The origin mechanism belongs to chunk T2 and is not in this worktree, so
	# every test that is NOT about its absence points the single coupling at the
	# stub. The two tests that ARE about its absence unset this.
	export GCP_TF_DEMO_DEX_ORIGIN_CMD="${stubdir}/dex-origin"

	# The name resolves by default. Tests about resolution failure clear it.
	export STUB_RESOLVABLE="${TS_FQDN}"

	# Short deadlines: a failing health probe is a real wait otherwise.
	export GCP_TF_DEMO_HEALTH_WAIT_SECONDS=2
	export GCP_TF_DEMO_HEALTH_INTERVAL_SECONDS=1

	stub_curl 200
}

# A hand-off carrying everything the driver reads. Deliberately carries NO
# tailscale_hostname, so the default path under test is the derivation
# (`sl-<env>`) that chunk T1 mirrors in Terraform — the case that has to work
# before T1's output block lands.
write_handoff() {
	local op="${1-sl-operator@acme-real-project-42.iam.gserviceaccount.com}"
	jq -n \
		--arg env "${ENV_KEY}" \
		--arg op "${op}" \
		'{schema: "signalloom.gcp.handoff/v1", schema_version: 1,
		  project_id: "acme-real-project-42", environment_key: $env, env: $env,
		  region: "europe-west2", zone: "europe-west2-a",
		  instance_name: ("sl-" + $env + "-demo"), internal_ip: "10.4.0.7",
		  app_port: 30754, state_bucket: "acme-tfstate",
		  state_prefix: ("osramp/environments/" + $env),
		  deploy_sa: "deployer@acme-real-project-42.iam.gserviceaccount.com",
		  operator_sa: $op, access_mode: "tailscale", hostname: "demo-7.acme.example"}
		 | if $op == "" then del(.operator_sa) else . end' \
		>"${root}/deploy/gcp/${ENV_KEY}.handoff.json"
}

# write_ts_status <hostname> <online true|false> [dnsname]
#
# The tailnet as this machine's tailscaled sees it. A `.Self` entry is always
# present because the real client always has one, and the driver's lookup
# includes Self so it still works when run from the demo node itself.
write_ts_status() {
	local host="$1" online="$2" dns="${3-${1}.example-tailnet.ts.net.}"
	jq -n --arg h "$host" --arg d "$dns" --argjson on "$online" \
		'{Self: {HostName: "operator-laptop", DNSName: "operator-laptop.example-tailnet.ts.net.",
		         TailscaleIPs: ["100.64.0.1"], Online: true},
		  MagicDNSSuffix: "example-tailnet.ts.net",
		  Peer: {"nodekey:aaa": {HostName: $h, DNSName: $d,
		                         TailscaleIPs: ["100.64.0.9"], Online: $on}}}' \
		>"${ts_json}"
}

# A tailnet this environment's node is not in at all — the expected look of a
# suspended demo VM, because the node is ephemeral and gets removed rather than
# shown offline.
write_ts_status_without_node() {
	jq -n \
		'{Self: {HostName: "operator-laptop", DNSName: "operator-laptop.example-tailnet.ts.net.",
		         TailscaleIPs: ["100.64.0.1"], Online: true},
		  MagicDNSSuffix: "example-tailnet.ts.net",
		  Peer: {"nodekey:bbb": {HostName: "someone-elses-box",
		                         DNSName: "someone-elses-box.example-tailnet.ts.net.",
		                         TailscaleIPs: ["100.64.0.5"], Online: true}}}' \
		>"${ts_json}"
}

stub_curl() { # stub_curl <status-code-to-emit>
	printf '#!/usr/bin/env bash\nprintf %%s %q\n' "$1" >"${stubdir}/curl-stub"
	chmod +x "${stubdir}/curl-stub"
	export GCP_TF_DEMO_CURL="${stubdir}/curl-stub"
}

gcloud_log() { cat "${log}" 2>/dev/null || true; }
dex_log() { cat "${dexlog}" 2>/dev/null || true; }

run_make() { run make -C "${REPO_ROOT}" "$@"; }

# Apply a sed expression to the driver copy under test, and PROVE it applied.
#
# A sed expression that matches nothing exits 0 and changes nothing, so the
# mutation test that follows would run against correct code and pass — a
# mutation proof that proves the opposite of what it claims. This repo has
# shipped exactly that: a scripted edit that no-opped while printing success.
mutate() {
	local before after
	before="$(md5sum <"${driver}")"
	sed -i "$1" "${driver}"
	after="$(md5sum <"${driver}")"
	[ "$before" != "$after" ] || {
		echo "the mutation '$1' matched nothing — the test that follows would be vacuous"
		return 1
	}
	grep -q . "${driver}" || {
		echo "the mutation emptied the driver"
		return 1
	}
}

# ─── Static properties ──────────────────────────────────────────────────────

@test "TS the driver is still shellcheck clean with the tailscale path in it" {
	command -v shellcheck >/dev/null || skip "shellcheck not installed"
	run shellcheck "${DRIVER_SRC}"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "TS the driver dispatches every tailscale subcommand" {
	# A subcommand that is not wired into the dispatch falls through to the
	# usage error, which exits non-zero — indistinguishable from a refusal, and
	# it would make every negative test below pass for the wrong reason.
	for sub in ts-up ts-status funnel-up funnel-down; do
		run "${driver}" "${sub}"
		[[ "$output" != *"usage: demo-up.sh"* ]] || {
			echo "subcommand '${sub}' fell through to the usage error — it is not dispatched"
			return 1
		}
	done
}

@test "TS the tailscale path hardcodes no tailnet, project, zone or instance" {
	# A tailnet name typed here is a value that goes stale silently and promises
	# a URL under a tailnet the operator is not on. The node's FQDN is read from
	# `tailscale status --json` for exactly this reason.
	#
	# Presence first: `[ "$status" -ne 0 ]` on a grep reads a MISSING FILE as
	# "pattern absent", which is a pass earned by scanning nothing.
	[ -f "${DRIVER_SRC}" ]

	local hits
	hits="$(grep -nE '[a-z0-9]+\.ts\.net|cp-dev-ajm|acme-real-project|[a-z0-9-]+\.iam\.gserviceaccount\.com|europe-west[0-9]-[a-z]' \
		"${DRIVER_SRC}" | grep -v '<tailnet>' || true)"
	[ -z "$hits" ] || {
		echo "hardcoded tailnet or estate identity in the driver:"
		echo "$hits"
		return 1
	}

	# The scan must be capable of finding something, or its silence is worthless.
	local control
	control="$(printf '%s\n' 'url = "https://sl-demo-1.taild4da3.ts.net"' |
		grep -cE '[a-z0-9]+\.ts\.net' || true)"
	[ "$control" -eq 1 ]
}

@test "TS the tailscale path introduces no self-matching process kill" {
	# `pkill -f <pattern>` matches the shell carrying the command text and kills
	# it silently — measured in this repo as a bare exit 144 with no output at
	# all, which reads as a hung command rather than a self-kill. The remote
	# `bash -lc` this driver's commands run under has the same property.
	[ -f "${DRIVER_SRC}" ]
	local hits
	hits="$(grep -nE '\b(pgrep|pkill)\b' "${DRIVER_SRC}" |
		grep -vE '^[0-9]+: *#' | grep -v -- '-x' || true)"
	[ -z "$hits" ] || {
		echo "a pattern-matching process kill was introduced: ${hits}"
		return 1
	}
}

# ─── The Make contract ──────────────────────────────────────────────────────

@test "TS every tailscale target exists as a real make target" {
	# Presence, not just absence. A contract test that only greps for a refusal
	# passes hardest when the target has been DELETED.
	for t in ${TS_TARGETS}; do
		run make -C "${REPO_ROOT}" -n "$t" ENV=demo-9
		[[ "${output}" != *"No rule to make target"* ]] || {
			echo "target ${t} does not exist"
			return 1
		}
	done
}

@test "TS every tailscale target is declared .PHONY" {
	for t in ${TS_TARGETS}; do
		grep -Eq "^\.PHONY:( .*)? ${t}( |\$)" "${MAKEFILE}" || {
			echo "${t} is not declared .PHONY"
			return 1
		}
	done
}

@test "TS every tailscale target appears in make help" {
	run_make help
	[ "$status" -eq 0 ]
	for t in ${TS_TARGETS}; do
		[[ "${output}" == *"${t}"* ]] || {
			echo "${t} is missing from make help — it has no '## ' comment"
			return 1
		}
	done
}

@test "TS every tailscale target refuses to run without ENV and says so" {
	# Asserted on "ENV is required FOR", which is the Makefile guard's own
	# wording, not on the bare phrase.
	#
	# The bare phrase was the first version of this test and it was worthless.
	# The driver has an INDEPENDENT require_env whose message is
	# "demo-up: ENV is required. Usage: …" — so with $(gcp_tf_require_env)
	# deleted from all four recipes the targets still ran, the driver still
	# refused, and this test still passed. Measured: 19 occurrences of the guard
	# in the Makefile reduced to 15, and the suite stayed green.
	for t in ${TS_TARGETS}; do
		run_make "$t"
		[ "$status" -ne 0 ] || {
			echo "${t} succeeded with no ENV"
			return 1
		}
		[[ "${output}" == *"ENV is required for '${t}'"* ]] || {
			echo "${t} did not refuse at the MAKE guard — only the driver stopped it: ${output}"
			return 1
		}
	done
}

@test "TS every tailscale target rejects a production-shaped key" {
	for t in ${TS_TARGETS}; do
		run_make "$t" ENV=prod-1
		[ "$status" -ne 0 ] || {
			echo "${t} accepted ENV=prod-1"
			return 1
		}
		# Again the MAKE guard's own wording. The driver independently rejects
		# invalid keys with "is not a valid environment key" too, so the obvious
		# assertion passes with $(gcp_tf_require_env) deleted — the same
		# passes-hardest-when-deleted shape caught on the ENV test above. Only the
		# Makefile explains why a prod-shaped key is refused on principle.
		[[ "${output}" == *"prod-shaped key here would put production"* ]] || {
			echo "${t} did not reject prod-1 at the MAKE guard: ${output}"
			return 1
		}
	done
}

@test "TS every tailscale target requires impersonation" {
	# All four reach the cloud — ts-status included, because it reads the VM's
	# state and asks the VM whether it is publishing.
	for t in ${TS_TARGETS}; do
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

@test "TS each tailscale target forwards ENV and invokes its own subcommand" {
	# Asserted per target rather than once, because a copy-paste that leaves two
	# targets calling the same subcommand is the likeliest error in a family
	# built by duplication, and it is invisible to a single spot check.
	local t sub
	for pair in "gcp-tf-ts-up:ts-up" "gcp-tf-ts-status:ts-status" \
		"gcp-tf-funnel-up:funnel-up" "gcp-tf-funnel-down:funnel-down"; do
		t="${pair%%:*}"
		sub="${pair##*:}"
		run make -C "${REPO_ROOT}" -n "$t" ENV=demo-9
		[ "$status" -eq 0 ]
		[[ "${output}" == *"GCP_TF_DEMO_ENV='demo-9'"* ]] || {
			echo "${t} does not forward ENV to the driver: ${output}"
			return 1
		}
		[[ "${output}" == *"demo-up.sh' ${sub}"* ]] || {
			echo "${t} does not invoke the driver's '${sub}' subcommand: ${output}"
			return 1
		}
	done
}

@test "TS REGRESSION the IAP fallback family still exists and still guards ENV" {
	# "Tailscale becomes primary" is about which path leads, not about deleting
	# the tested one. If this goes red, this chunk removed the fallback.
	for t in ${IAP_TARGETS}; do
		run make -C "${REPO_ROOT}" -n "$t" ENV=demo-9
		[[ "${output}" != *"No rule to make target"* ]] || {
			echo "IAP target ${t} was removed"
			return 1
		}
		run_make "$t"
		[ "$status" -ne 0 ] || {
			echo "${t} succeeded with no ENV"
			return 1
		}
		[[ "${output}" == *"ENV is required"* ]]
	done
}

@test "TS REGRESSION the IAP fallback family is still in make help" {
	run_make help
	[ "$status" -eq 0 ]
	for t in ${IAP_TARGETS}; do
		[[ "${output}" == *"${t}"* ]] || {
			echo "${t} vanished from make help — the fallback is undiscoverable"
			return 1
		}
	done
}

# ─── The node has to be there, and it has to be reachable ───────────────────

@test "TS ts-up refuses when there is no tailscale client on this machine" {
	GCP_TF_DEMO_TAILSCALE="${BATS_TEST_TMPDIR}/no-such-tailscale" run "${driver}" ts-up
	[ "$status" -ne 0 ]
	[[ "$output" == *"on PATH"* ]]
	[[ "$output" == *"gcp-tf-public"* ]] || {
		echo "the refusal did not name the IAP fallback for an operator who cannot install it: ${output}"
		return 1
	}
}

@test "TS ts-up refuses when tailscaled here is down, and says it is about THIS machine" {
	export STUB_TS_DAEMON_DOWN=1
	run "${driver}" ts-up
	[ "$status" -ne 0 ]
	[[ "$output" == *"tailscale up"* ]]
	[[ "$output" == *"THIS machine"* ]] || {
		echo "the refusal blamed the estate for a local daemon: ${output}"
		return 1
	}
}

@test "TS ts-up fails clearly when the node is not in the tailnet, and lists what is" {
	write_ts_status_without_node
	run "${driver}" ts-up
	[ "$status" -ne 0 ]
	[[ "$output" == *"no node named 'sl-${ENV_KEY}'"* ]] || {
		echo "the failure did not name the node it looked for: ${output}"
		return 1
	}
	# The three causes are indistinguishable from here, so the message must name
	# all three rather than pick one and send the reader down it.
	[[ "$output" == *"tagOwners"* ]]
	[[ "$output" == *"ACL"* ]]
	[[ "$output" == *"someone-elses-box"* ]] || {
		echo "the failure did not list the nodes it CAN see, which is the one piece of evidence available: ${output}"
		return 1
	}
}

@test "TS ts-up fails clearly when the node is OFFLINE, distinctly from absent" {
	write_ts_status "${TS_HOST}" false
	run "${driver}" ts-up
	[ "$status" -ne 0 ]
	[[ "$output" == *"OFFLINE"* ]] || {
		echo "an offline node was not reported as offline: ${output}"
		return 1
	}
	[[ "$output" == *"not a name resolution problem"* ]] || {
		echo "the offline message did not rule out the causes it is confusable with: ${output}"
		return 1
	}
	[[ "$output" != *"no node named"* ]] || {
		echo "an OFFLINE node was reported as absent — those invite different fixes"
		return 1
	}
}

@test "TS ts-up explains a node with no MagicDNS name as a tailnet setting" {
	write_ts_status "${TS_HOST}" true ""
	run "${driver}" ts-up
	[ "$status" -ne 0 ]
	[[ "$output" == *"MagicDNS is disabled"* ]]
	[[ "$output" == *"admin"* ]] || {
		echo "the failure did not say where to turn MagicDNS on: ${output}"
		return 1
	}
}

@test "TS ts-up refuses when MagicDNS does not resolve HERE, before any cloud call" {
	# The direct analogue of the IAP path's /etc/hosts check, and it exists for
	# the same reason: the health probe proves the dashboard answers, not that a
	# browser on this machine can reach the same URL.
	export STUB_RESOLVABLE=""
	run "${driver}" ts-up
	[ "$status" -ne 0 ] || {
		echo "ts-up proceeded with a name this machine cannot resolve — the browser would fail on the click"
		return 1
	}
	[[ "$output" == *"does not resolve on this machine"* ]]
	[[ "$output" == *"accept-dns"* ]] || {
		echo "the refusal did not name the likeliest fix: ${output}"
		return 1
	}
	# It must fail FIRST. Failing after publishing would mean waiting a minute to
	# be told about a setting on this laptop.
	[ -z "$(gcloud_log)" ] || {
		echo "the resolution check ran after a cloud call, not before it: $(gcloud_log)"
		return 1
	}
}

@test "TS the MagicDNS check is overridable for scripted, browserless use" {
	export STUB_RESOLVABLE=""
	export GCP_TF_DEMO_SKIP_MAGICDNS_CHECK=1
	stub_curl 200
	run "${driver}" ts-up
	[[ "$output" == *"returned 200"* ]] || {
		echo "the override did not let a browserless run through: ${output}"
		return 1
	}
}

# ─── The health gate ────────────────────────────────────────────────────────

@test "TS ts-up refuses to hand over a URL when the dashboard never answers" {
	stub_curl 000
	run "${driver}" ts-up
	[ "$status" -ne 0 ] || {
		echo "ts-up exited 0 with a dashboard that never answered — the gate is decoration"
		return 1
	}
	[[ "$output" != *"Log in through Dex"* ]] || {
		echo "ts-up printed the login instructions for a demo it had not reached"
		return 1
	}
	# The three things behind that name are distinguishable by the status code,
	# and the message has to say which is which or it sends the reader to the
	# wrong layer.
	[[ "$output" == *"HTTPS certs"* ]]
	[[ "$output" == *"502"* ]]
}

@test "TS ts-up prints the MagicDNS URL and the health verdict only after a 200" {
	stub_curl 200
	run "${driver}" ts-up
	[ "$status" -eq 0 ] || {
		echo "ts-up failed on a healthy estate: ${output}"
		return 1
	}
	[[ "$output" == *"https://${TS_FQDN}"* ]] || {
		echo "ts-up did not print the MagicDNS URL: ${output}"
		return 1
	}
	[[ "$output" == *"returned 200 — verified before you clicked"* ]] || {
		echo "ts-up did not report the health verdict on a healthy estate: ${output}"
		return 1
	}
	[[ "$output" == *"NOTHING to add to /etc/hosts"* ]] || {
		echo "ts-up did not state the ergonomic difference from the IAP path: ${output}"
		return 1
	}
}

@test "TS ts-up states that the URL is tailnet-only, not public" {
	stub_curl 200
	run "${driver}" ts-up
	[[ "$output" == *"TAILNET only"* ]] || {
		echo "ts-up did not state the scope of the URL it handed over: ${output}"
		return 1
	}
	[[ "$output" == *"Not from the public internet"* ]]
}

@test "TS ts-up configures serve on the VM, not funnel" {
	stub_curl 200
	run "${driver}" ts-up
	[[ "$(gcloud_log)" == *"tailscale serve"* ]] || {
		echo "ts-up never configured tailscale serve: $(gcloud_log)"
		return 1
	}
	[[ "$(gcloud_log)" != *"tailscale funnel"* ]] || {
		echo "ts-up configured FUNNEL — it would have made the demo public without being asked"
		return 1
	}
}

@test "TS ts-up gives the SNI hostname a loopback alias on the VM" {
	# tailscale serve dials its backend by NAME so the Gateway has an SNI value
	# to route on. An IP literal sends no SNI at all and the Gateway closes the
	# connection mid-handshake, which reads as a dead dashboard.
	stub_curl 200
	run "${driver}" ts-up
	[[ "$(gcloud_log)" == *"/etc/hosts"* ]] || {
		echo "no loopback alias was created on the VM: $(gcloud_log)"
		return 1
	}
	[[ "$(gcloud_log)" == *"https+insecure://dashboard.osramp.acme.local"* ]] || {
		echo "the serve backend is not dialled by the SNI name: $(gcloud_log)"
		return 1
	}
}

@test "TS ts-up fails usably when the tailnet has no HTTPS certificates" {
	export STUB_TS_SERVE_RC=1
	stub_curl 200
	run "${driver}" ts-up
	[ "$status" -ne 0 ]
	[[ "$output" == *"HTTPS certs are not enabled"* ]] || {
		echo "a certificate failure was not explained as a tailnet setting: ${output}"
		return 1
	}
}

# ─── Dex has exactly one issuer ─────────────────────────────────────────────

@test "TS funnel-up refuses when another origin holds Dex, and names the holder" {
	export STUB_DEX_CURRENT="https://abc123.ngrok.app"
	run "${driver}" funnel-up
	[ "$status" -ne 0 ] || {
		echo "funnel-up took the Dex issuer from another live demo"
		return 1
	}
	[[ "$output" == *"https://abc123.ngrok.app"* ]] || {
		echo "the refusal did not name the current holder: ${output}"
		return 1
	}
	[[ "$output" == *"exactly ONE issuer"* ]]
	[[ "$output" == *"public-tunnel.sh down"* ]] || {
		echo "the refusal did not say how to release it: ${output}"
		return 1
	}
	# And it refuses BEFORE reconfiguring anything.
	[[ "$(gcloud_log)" != *"tailscale funnel"* ]] || {
		echo "funnel was configured before the origin conflict was checked"
		return 1
	}
}

@test "TS ts-up refuses when another origin holds Dex, and names the holder" {
	export STUB_DEX_CURRENT="https://abc123.ngrok.app"
	run "${driver}" ts-up
	[ "$status" -ne 0 ]
	[[ "$output" == *"https://abc123.ngrok.app"* ]]
	[[ "$(gcloud_log)" != *"tailscale serve"* ]] || {
		echo "serve was configured before the origin conflict was checked"
		return 1
	}
}

@test "TS an origin already held by THIS run is not a conflict" {
	# Re-running ts-up on a live demo must be idempotent, not a refusal naming
	# itself as the culprit.
	export STUB_DEX_CURRENT="https://${TS_FQDN}"
	stub_curl 200
	run "${driver}" ts-up
	[ "$status" -eq 0 ] || {
		echo "a re-run of a live demo was refused against its own origin: ${output}"
		return 1
	}
}

@test "TS ts-up claims the Dex origin at the MagicDNS URL" {
	stub_curl 200
	run "${driver}" ts-up
	[[ "$(dex_log)" == *"apply https://${TS_FQDN}"* ]] || {
		echo "ts-up never claimed the origin, so the login would bounce: $(dex_log)"
		return 1
	}
}

@test "TS funnel-up and ts-up claim the SAME origin" {
	# serve and funnel publish the same MagicDNS name with the same certificate;
	# funnel only adds public reachability. If these ever diverge, moving between
	# them silently breaks login.
	stub_curl 200
	run "${driver}" ts-up
	: >"${dexlog}"
	run "${driver}" funnel-up
	[[ "$(dex_log)" == *"apply https://${TS_FQDN}"* ]] || {
		echo "funnel-up claimed a different origin from ts-up: $(dex_log)"
		return 1
	}
}

@test "TS ts-up refuses when T2's origin mechanism is absent, naming the file" {
	unset GCP_TF_DEMO_DEX_ORIGIN_CMD
	[ ! -f "${root}/scripts/lib/dex-origin.sh" ]
	run "${driver}" ts-up
	[ "$status" -ne 0 ] || {
		echo "ts-up served a new origin with no way to repoint Dex — the login would bounce"
		return 1
	}
	[[ "$output" == *"scripts/lib/dex-origin.sh"* ]]
	[[ "$output" == *"gcp-tf-public"* ]] || {
		echo "the refusal did not name the path that works today: ${output}"
		return 1
	}
}

@test "TS the origin claim is skippable for ts-up, with the consequence stated" {
	unset GCP_TF_DEMO_DEX_ORIGIN_CMD
	export GCP_TF_DEMO_SKIP_DEX_ORIGIN=1
	stub_curl 200
	run "${driver}" ts-up
	[ "$status" -eq 0 ]
	[[ "$output" == *"LOGIN WILL BOUNCE"* ]] || {
		echo "the override did not state what it costs: ${output}"
		return 1
	}
}

@test "TS the origin claim is NOT skippable for funnel-up" {
	# A bouncing login on a tailnet URL is an inconvenience. On a URL the whole
	# internet can reach it is a broken thing published under this estate's name,
	# so the escape hatch deliberately does not exist here.
	unset GCP_TF_DEMO_DEX_ORIGIN_CMD
	export GCP_TF_DEMO_SKIP_DEX_ORIGIN=1
	run "${driver}" funnel-up
	[ "$status" -ne 0 ] || {
		echo "funnel-up published a PUBLIC URL with an unpatched Dex because a skip flag was set"
		return 1
	}
	[[ "$output" == *"scripts/lib/dex-origin.sh"* ]]
}

# ─── Funnel is the only public listener in this estate ──────────────────────

@test "TS funnel-up says plainly that it exposes the demo to the public internet" {
	stub_curl 200
	run "${driver}" funnel-up
	[[ "$output" == *"PUBLIC INTERNET"* ]] || {
		echo "funnel-up did not state that it creates a public listener: ${output}"
		return 1
	}
	[[ "$output" == *"gcp-tf-funnel-down"* ]] || {
		echo "funnel-up did not say how to switch it off: ${output}"
		return 1
	}
	[[ "$output" == *"does not expire"* ]] || {
		echo "funnel-up implied the exposure ends on its own: ${output}"
		return 1
	}
}

@test "TS funnel-up warns BEFORE it configures the public listener" {
	# Printed after the fact, the warning is a description of something that has
	# already happened rather than a chance to stop.
	stub_curl 200
	run "${driver}" funnel-up
	local warn_line cfg_line
	warn_line="$(printf '%s\n' "$output" | grep -n 'PUBLIC INTERNET' | head -1 | cut -d: -f1)"
	cfg_line="$(printf '%s\n' "$output" | grep -n "configuring 'tailscale funnel'" | head -1 | cut -d: -f1)"
	[ -n "$warn_line" ] && [ -n "$cfg_line" ] || {
		echo "could not find both the warning and the configuration step: ${output}"
		return 1
	}
	[ "$warn_line" -lt "$cfg_line" ] || {
		echo "the public-exposure warning printed after the listener was configured"
		return 1
	}
}

@test "TS funnel-up refuses usably when the tailnet policy grants no funnel attr" {
	export STUB_TS_FUNNEL_RC=1
	stub_curl 200
	run "${driver}" funnel-up
	[ "$status" -ne 0 ]
	[[ "$output" == *"nodeAttrs"* ]] || {
		echo "a policy refusal was not explained as a nodeAttrs entry: ${output}"
		return 1
	}
}

@test "TS funnel-down switches funnel off and leaves the tailnet demo standing" {
	run "${driver}" funnel-down
	[ "$status" -eq 0 ] || {
		echo "funnel-down failed: ${output}"
		return 1
	}
	[[ "$(gcloud_log)" == *"tailscale funnel"*"off"* ]] || {
		echo "funnel-down never turned funnel off: $(gcloud_log)"
		return 1
	}
	[[ "$output" == *"Funnel is OFF"* ]]
	[[ "$output" == *"still live for this tailnet"* ]] || {
		echo "funnel-down did not say the tailnet demo survives, inviting a needless rebuild: ${output}"
		return 1
	}
	# It must NOT restore the Dex origin: the demo is still live at that URL.
	[[ "$(dex_log)" != *"restore"* ]] || {
		echo "funnel-down restored the Dex issuer and broke the tailnet demo it left running"
		return 1
	}
}

@test "TS funnel-down says the listener may still be up when it cannot switch it off" {
	export STUB_TS_FUNNEL_OFF_RC=1
	run "${driver}" funnel-down
	[ "$status" -ne 0 ]
	[[ "$output" == *"STILL BE UP"* ]] || {
		echo "a failed funnel-down did not warn that the public listener may survive: ${output}"
		return 1
	}
}

# ─── Status ─────────────────────────────────────────────────────────────────

@test "TS ts-status reports the node, its MagicDNS name, its IP and the health" {
	stub_curl 200
	run "${driver}" ts-status
	[ "$status" -eq 0 ]
	[[ "$output" == *"${TS_FQDN}"* ]]
	[[ "$output" == *"100.64.0.9"* ]]
	[[ "$output" == *"online:    true"* ]]
	[[ "$output" == *"HEALTHY"* ]] || {
		echo "ts-status did not report dashboard health: ${output}"
		return 1
	}
}

@test "TS ts-status reports who holds the Dex origin" {
	export STUB_DEX_CURRENT="https://abc123.ngrok.app"
	stub_curl 200
	run "${driver}" ts-status
	[[ "$output" == *"dex origin: https://abc123.ngrok.app"* ]] || {
		echo "ts-status did not report the origin holder, which is the first thing to check when login bounces: ${output}"
		return 1
	}
}

@test "TS ts-status reports an offline node without pretending to be healthy" {
	write_ts_status "${TS_HOST}" false
	stub_curl 200
	run "${driver}" ts-status
	[ "$status" -ne 0 ] || {
		echo "ts-status exited 0 for a node that is offline"
		return 1
	}
	[[ "$output" == *"OFFLINE"* ]]
}

# ─── MUTATIONS ──────────────────────────────────────────────────────────────
#
# Each breaks the real guard in the copy under test and asserts the matching
# test above goes GREEN. A guard whose test cannot fail is decoration.

@test "TS MUTATION health-gate: accepting any status makes the dead-dashboard test pass" {
	mutate 's|^    if \[ "\$code" = "200" \]; then$|    if true; then|'
	stub_curl 000
	run "${driver}" ts-up
	[[ "$output" == *"verified before you clicked"* ]] || {
		echo "the health gate's test cannot fail — a mutated gate still refused a dead dashboard: ${output}"
		return 1
	}
}

@test "TS MUTATION offline-check: removing it lets an offline node through" {
	mutate 's|^  if \[ "\$TS_ONLINE" != "true" \]; then$|  if false; then|'
	write_ts_status "${TS_HOST}" false
	stub_curl 200
	run "${driver}" ts-up
	[ "$status" -eq 0 ] || {
		echo "the offline check's test cannot fail — removing it changed nothing: ${output}"
		return 1
	}
	[[ "$output" == *"returned 200"* ]]
}

@test "TS MUTATION magicdns-check: removing it lets an unresolvable name through" {
	mutate 's|^  require_magicdns$|  :|'
	export STUB_RESOLVABLE=""
	stub_curl 200
	run "${driver}" ts-up
	[[ "$output" == *"returned 200"* ]] || {
		echo "the MagicDNS check's test cannot fail — removing the guard changed nothing: ${output}"
		return 1
	}
}

@test "TS MUTATION origin-conflict: removing it lets funnel-up steal a live issuer" {
	mutate 's|^  require_no_conflicting_origin "\$base"$|  :|'
	export STUB_DEX_CURRENT="https://abc123.ngrok.app"
	stub_curl 200
	run "${driver}" funnel-up
	[ "$status" -eq 0 ] || {
		echo "the origin-conflict test cannot fail — removing the guard did not let funnel-up proceed: ${output}"
		return 1
	}
	[[ "$(gcloud_log)" == *"tailscale funnel"* ]] || {
		echo "the mutated funnel-up still never configured funnel, so the guard's test proves nothing"
		return 1
	}
}

@test "TS MUTATION dex-mechanism: removing the presence check serves a new origin blind" {
	mutate 's|^    require_dex_origin_mechanism "gcp-tf-ts-up"$|    :|'
	mutate 's|^  require_no_conflicting_origin "\$base"$|  :|'
	unset GCP_TF_DEMO_DEX_ORIGIN_CMD
	stub_curl 200
	run "${driver}" ts-up
	# With the presence check gone the driver falls through to the REMOTE
	# invocation, which the stub gcloud answers 0 — so it proceeds, which is
	# exactly the silent-success shape the check exists to prevent.
	[ "$status" -eq 0 ] || {
		echo "the mechanism check's test cannot fail — removing it did not let the run proceed: ${output}"
		return 1
	}
}

@test "TS MUTATION make-guard: dropping require_env lets a target run with no ENV" {
	# Mutates a COPY of the Makefile. Mutating the real one and restoring it is
	# how in-progress work gets reverted by a proof harness, and a failed restore
	# leaves the repo broken for the next test rather than for this one.
	local mk="${BATS_TEST_TMPDIR}/Makefile.mutated"
	local before after
	cp "${MAKEFILE}" "${mk}"
	before="$(md5sum <"${mk}")"
	perl -0pi -e 's/(gcp-tf-ts-up:.*?\n)\t\$\(gcp_tf_require_env\)\n/$1/s' "${mk}"
	after="$(md5sum <"${mk}")"
	[ "$before" != "$after" ] || {
		echo "the Makefile mutation matched nothing — the assertion below would be vacuous"
		return 1
	}

	# Asserted on the Makefile guard's OWN wording, not on the shared phrase.
	# The driver has an independent require_env, and its message also contains
	# "ENV is required" — so the obvious assertion passes whether the Make guard
	# is present or deleted, which is a mutation proof that proves nothing. The
	# Make guard says "ENV is required for '<target>'"; the driver says
	# "demo-up: ENV is required. Usage: ...".
	run make -C "${REPO_ROOT}" -f "${mk}" gcp-tf-ts-up
	[[ "${output}" != *"ENV is required for"* ]] || {
		echo "the Make ENV guard's test cannot fail — the target still refused with the guard deleted"
		return 1
	}

	# And the discovery this proof produced rather than assumed: the defence is
	# DOUBLED. With the Makefile guard gone the recipe runs, and the driver's own
	# require_env stops it. That is the honest answer to "how safe is this
	# really", and it is a stronger answer than either mechanism alone — so it is
	# asserted here rather than left as a comment.
	[[ "${output}" == *"demo-up: ENV is required"* ]] || {
		echo "with the Make guard removed nothing stopped the run at all: ${output}"
		return 1
	}
}
