#!/usr/bin/env bats
#
# spire-server's CA must survive a pod restart.
#
# ── The defect this pins ───────────────────────────────────────────────────
#
# spire-server's data_dir held the sqlite datastore AND the CA private keys, and
# had NO volume of any kind — so both lived in the container's writable layer. A
# restart (eviction, node pressure, image bump, any pod-template edit) issued a
# NEW CA, NEW JWT signing keys, and an EMPTY registration table.
#
# That would be survivable on its own. What made it unrecoverable is the other
# half of the pair: spire-agent's data_dir IS persistent — a hostPath at
# /var/lib/spire-agent/data — so the agent kept the bundle for the CA that no
# longer existed and crash-looped on
#
#   x509svid: could not verify leaf certificate:
#   x509: certificate signed by unknown authority
#
# forever. Observed on kind-osramp: CrashLoopBackOff, 1528 restarts over 6d19h.
# Join tokens are single-use, so each of those restarts burned one. Recovery
# needed node access to clear the agent's hostPath, which is `docker exec` on
# kind and `gcloud compute ssh` on GCP — scripts/lib/spire-trust-anchor.sh
# deliberately REFUSES to attempt it and prints the manual steps instead.
#
# The fix is to make the server the durable side, matching the agent: a PVC at
# data_dir, so the CA the agent already trusts is still the CA after a restart.
#
# ── Why these assertions are shaped the way they are ───────────────────────
#
# Every path here is DERIVED from server.conf rather than written down twice.
# The failure mode is not "somebody deletes the PVC" — it is "somebody moves
# data_dir, or points keys_path or the sqlite connection_string somewhere else,
# and the PVC keeps existing while no longer covering the CA". A test that
# hardcodes /run/spire/data stays green through exactly that change and reports
# durability the repo no longer has. So the mount path is read out of the
# ConfigMap and compared, and the two artefacts that ARE the CA — keys.json and
# datastore.sqlite3 — are each required to sit under the mounted volume.
#
# Negatives are collected into a variable and asserted with a positive
# comparison. A bare `! grep …` in a bats body is exempt from errexit and can
# never fail the test; this repo has been bitten by that.
#
# yq here is mikefarah v4, which has no `--arg`. Values cross into the
# expression through the environment and strenv(); a `--arg` written from jq
# muscle memory fails with `unknown flag`, which at least fails loudly.

setup() {
	root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
	overlay="$root/d2-signalloom/infra/inf-bao/controllers/local"
	config="$root/d2-signalloom/infra/inf-bao/controllers/base/spire-openbao-config.yaml"
	rendered="$BATS_TEST_TMPDIR/rendered.yaml"
	kubectl kustomize "$overlay" >"$rendered"
	[ -s "$rendered" ]
}

# Run a yq expression over a multi-document stream and return ONLY the matches.
#
# mikefarah yq emits one output document per INPUT document, so `select(...)`
# over a 20-document kustomize render returns the match surrounded by 19 empty
# documents. `-N` drops the `---` separators but leaves the blank lines, so
# $output ends up as "\n\n\nfalse\tfalse\n\n\n" and every `[ "$output" = ... ]`
# comparison fails against a manifest that is in fact correct — or, far worse,
# an `[ -n "$output" ]` check passes on nothing but the padding, which is a
# green test over an empty result set.
#
# Stripping blank lines cannot hide a genuine non-match: a no-match collapses to
# the empty string, which every caller below rejects with `[ -n "$output" ]`.
yq_match() { # expression file
	local out status
	out="$(yq -N -r "$1" "$2")"
	status=$?
	[ "$status" -eq 0 ] || return "$status"
	printf '%s\n' "$out" | sed '/^[[:space:]]*$/d'
}

# The server's own view of where its state lives. One derivation, read by every
# test below, so none of them can disagree with server.conf about what is meant
# to be durable.
server_conf() {
	yq_match 'select(.kind == "ConfigMap" and .metadata.name == "spire-server-config") | .data["server.conf"]' "$config"
}

server_data_dir() {
	server_conf | sed -n 's/.*data_dir[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# The volume name backing whichever mount covers the server's data_dir.
server_data_volume() {
	local dir
	dir="$(server_data_dir)"
	[ -n "$dir" ] || return 1
	DATA_DIR="$dir" yq_match '
		select(.kind == "Deployment" and .metadata.name == "spire-server")
		| .spec.template.spec.containers[]
		| select(.name == "spire-server")
		| .volumeMounts[]
		| select(.mountPath == strenv(DATA_DIR))
		| .name' "$rendered"
}

@test "server.conf still declares a data_dir for this suite to reason about" {
	# Mechanism-presence check, not decoration. Every other test here derives
	# its expectation from this string; if the extraction silently returns
	# nothing, the mount comparison below compares "" to "" and the whole file
	# passes over a Deployment with no volumes at all.
	run server_data_dir
	[ "$status" -eq 0 ]
	[ -n "$output" ]
	[[ "$output" == /* ]]
}

@test "the spire-server data_dir is mounted from a PersistentVolumeClaim" {
	# The fix itself. Before it, data_dir had no volumeMount at all — not an
	# emptyDir, nothing — so this resolves to an empty volume name and fails on
	# the -n below rather than on the claim lookup.
	run server_data_volume
	[ "$status" -eq 0 ]
	volume="$output"
	[ -n "$volume" ]

	export VOL="$volume"
	run yq_match '
		select(.kind == "Deployment" and .metadata.name == "spire-server")
		| .spec.template.spec.volumes[]
		| select(.name == strenv(VOL))
		| .persistentVolumeClaim.claimName // ""' "$rendered"
	[ "$status" -eq 0 ]
	[ "$output" = "spire-server-data" ]
}

@test "the spire-server data volume is not backed by ephemeral storage" {
	run server_data_volume
	[ "$status" -eq 0 ]
	volume="$output"
	[ -n "$volume" ]

	# Asserted as a positive comparison against a captured value. `! yq …` or
	# `! grep …` as the last statement of a bats body is exempt from errexit and
	# would pass whatever the manifest said.
	export VOL="$volume"
	run yq_match '
		select(.kind == "Deployment" and .metadata.name == "spire-server")
		| .spec.template.spec.volumes[]
		| select(.name == strenv(VOL))
		| [(has("emptyDir")), (has("hostPath")), (has("configMap"))]
		| @tsv' "$rendered"
	[ "$status" -eq 0 ]
	[ "$output" = $'false\tfalse\tfalse' ]
}

@test "the PersistentVolumeClaim spire-server mounts is declared in this slice, RWO" {
	run server_data_volume
	[ "$status" -eq 0 ]
	volume="$output"
	[ -n "$volume" ]

	export VOL="$volume"
	run yq_match '
		select(.kind == "Deployment" and .metadata.name == "spire-server")
		| .spec.template.spec.volumes[]
		| select(.name == strenv(VOL))
		| .persistentVolumeClaim.claimName // ""' "$rendered"
	[ "$status" -eq 0 ]
	claim="$output"
	[ -n "$claim" ]

	# A Deployment referencing a claim nobody creates is indistinguishable from
	# the fix right up until the pod stays Pending on FailedScheduling.
	export CLAIM="$claim"
	run yq_match '
		select(.kind == "PersistentVolumeClaim" and .metadata.name == strenv(CLAIM))
		| [(.spec.accessModes | join(",")), (.spec.resources.requests.storage)]
		| @tsv' "$rendered"
	[ "$status" -eq 0 ]
	[ "$output" = $'ReadWriteOnce\t1Gi' ]
}

@test "the spire-server Deployment uses the Recreate strategy" {
	# Not stylistic. A RollingUpdate Deployment holding an RWO volume deadlocks
	# on its own upgrade: the replacement pod cannot attach the volume the
	# outgoing pod still holds, maxUnavailable keeps the old one alive, and the
	# rollout hangs until someone scales to zero by hand. The PVC and this line
	# are one change; landing either alone is worse than landing neither.
	run yq_match '
		select(.kind == "Deployment" and .metadata.name == "spire-server")
		| .spec.strategy.type // ""' "$rendered"
	[ "$status" -eq 0 ]
	[ "$output" = "Recreate" ]
}

@test "the CA private keys and the datastore both sit under the persisted mount" {
	# The assertion that survives a refactor. A PVC mounted at data_dir proves
	# nothing if KeyManager's keys_path or the sqlite connection_string points
	# outside it — the volume would persist an empty directory while the CA
	# went on living in the container layer, and every other test here would
	# stay green.
	run server_data_dir
	[ "$status" -eq 0 ]
	dir="$output"
	[ -n "$dir" ]

	run server_conf
	[ "$status" -eq 0 ]
	conf="$output"

	keys_path="$(sed -n 's/.*keys_path[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$conf" | head -1)"
	[ -n "$keys_path" ]
	[[ "$keys_path" == "$dir"/* ]]

	connection_string="$(sed -n 's/.*connection_string[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$conf" | head -1)"
	[ -n "$connection_string" ]
	[[ "$connection_string" == "$dir"/* ]]

	# And the mount that covers them is the PVC-backed one, not some other
	# volume that happens to share the prefix.
	run server_data_volume
	[ "$status" -eq 0 ]
	[ -n "$output" ]
}

@test "the spire-agent keeps its persistent data_dir" {
	# The other half of the pair, pinned deliberately. The alternative fix
	# considered and rejected was to make the agent ephemeral instead. If
	# someone later takes that route they must delete this test and say so —
	# silently landing both halves as ephemeral reintroduces the outage with no
	# durable side at all.
	agent="$root/d2-signalloom/infra/inf-bao/configs/base/spire-agent.yaml"
	run yq_match '
		select(.kind == "DaemonSet" and .metadata.name == "spire-agent")
		| .spec.template.spec.volumes[]
		| select(.name == "data")
		| .hostPath.path // ""' "$agent"
	[ "$status" -eq 0 ]
	[ "$output" = "/var/lib/spire-agent/data" ]
}
