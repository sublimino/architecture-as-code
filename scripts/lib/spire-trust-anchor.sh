#!/usr/bin/env bash
# The trust anchor OpenBao uses to validate SPIRE-issued JWT-SVIDs.
#
# OpenBao's JWT auth is configured here with `jwt_validation_pubkeys` — a static
# copy of SPIRE's JWT-SVID signing keys, taken once at bring-up. SPIRE rotates
# those keys on its own CA schedule (ca_ttl, 24h by default), so the copy is a
# snapshot of something that moves. When SPIRE activates the next key, every
# SPIFFE->OpenBao login fails with
#
#   error validating token: error verifying token signature:
#   no known key successfully validated the token signature
#
# and stays failed until the copy is refreshed. Nothing else breaks: the SPIRE
# entries still carry their selectors, the roles are still bound to the right
# subject and audience, and the workload still fetches a valid SVID. That is why
# the outage reads as an identity-wiring problem when it is a key-material one —
# on 2026-08-14 it presented as two probes failing and a coincidentally young
# planner pod, and the pod had nothing to do with it.
#
# ONE derivation, read by both sides. `sync_*` writes what `assert_*` reads, and
# both normalise SPIRE's JWK and OpenBao's PEM through openssl to the same
# canonical DER so they cannot disagree about what "the same key" means. A
# second, independent derivation would drift the way the snapshot did.

# base64(DER SubjectPublicKeyInfo) for one P-256 JWK coordinate pair.
_spire_jwk_to_der_b64() {
  local x="$1" y="$2" der status coordinate value
  der="$(mktemp)"
  {
    # SubjectPublicKeyInfo header for an uncompressed P-256 public key.
    printf '\x30\x59\x30\x13\x06\x07\x2a\x86\x48\xce\x3d\x02\x01\x06\x08\x2a\x86\x48\xce\x3d\x03\x01\x07\x03\x42\x00\x04'
    for coordinate in "$x" "$y"; do
      value="${coordinate//-/+}"
      value="${value//_/\/}"
      case $((${#value} % 4)) in
        2) value="${value}==" ;;
        3) value="${value}=" ;;
      esac
      printf '%s' "$value" | base64 -d
    done
  } >"$der"
  # Round-tripping through openssl rather than emitting the bytes we just built
  # is deliberate: OpenBao returns PEM, and only a shared canonicaliser makes a
  # key derived from a JWK and the same key read back from a PEM comparable.
  openssl pkey -pubin -inform DER -in "$der" -outform DER 2>/dev/null | base64 -w0
  status=$?
  rm -f "$der"
  ((status == 0)) || return 1
  printf '\n'
}

_der_b64_to_pem() {
  printf '%s' "$1" | base64 -d | openssl pkey -pubin -inform DER -outform PEM
}

# Every key SPIRE is currently willing to sign JWT-SVIDs with, one per line.
# SPIRE publishes both the outgoing and the incoming key across a rotation, so
# this is a set, never a single value.
spire_jwt_svid_keys() {
  local namespace="$1" bundle jwk_out jwk x y
  local -a jwks=()
  bundle="$(kubectl -n "$namespace" exec deployment/spire-server -- \
    /opt/spire/bin/spire-server bundle show -format spiffe)" || {
    printf 'SPIRE server unreachable: kubectl exec to deployment/spire-server in namespace %s failed — is the pod running?\n' "$namespace" >&2
    return 1
  }
  jwk_out="$(jq -r '
    .keys[] | select(.use == "jwt-svid" and .kty == "EC" and .crv == "P-256")
    | [.x, .y] | @tsv' <<<"$bundle")" || {
    printf 'SPIRE bundle is not valid JSON or jq extraction failed\n' >&2
    return 1
  }
  [[ -n "$jwk_out" ]] || {
    printf 'SPIRE bundle contains no P-256 JWT-SVID validation key — the bundle has %d total keys but none match use=jwt-svid, kty=EC, crv=P-256\n' \
      "$(jq '.keys | length' <<<"$bundle" 2>/dev/null || echo '?')" >&2
    return 1
  }
  mapfile -t jwks <<<"$jwk_out"
  for jwk in "${jwks[@]}"; do
    [[ -n "$jwk" ]] || continue
    IFS=$'\t' read -r x y <<<"$jwk"
    _spire_jwk_to_der_b64 "$x" "$y" || return 1
  done
}

# ── The server/agent persistence split, and why bao_up refuses ─────────────
#
# HISTORY, kept because the failure is still reachable and this is the clearest
# statement of it. spire-server's data_dir (/run/spire/data) had NO volume and
# NO PVC, so the sqlite datastore and the CA private keys lived in the
# container's writable layer. A restart — eviction, node pressure, image bump,
# any pod-template edit — gave a NEW CA, NEW JWT signing keys and NO
# registration entries.
#
# spire-agent's data_dir is a hostPath (/var/lib/spire-agent/data), so it
# SURVIVES that restart and reloaded a bundle for the CA that no longer existed.
#
# The two disagreed, and the agent crash-looped on
#
#   x509svid: could not verify leaf certificate:
#   x509: certificate signed by unknown authority
#
# bao_up could not fix this. It deletes the join-token Secret and the agent pod,
# which is right, but never clears the node directory — so the replacement pod
# reloaded the same stale bundle and crashed identically, forever. Diagnosed on
# kind-osramp 2026-08-23 after a deliberate spire-server restart; recovered by
# hand, twice. Worst observed state: CrashLoopBackOff, 1528 restarts over
# 6d19h, each one burning a single-use join token.
#
# ── The design decision HAS now been taken: the server got the PVC ─────────
#
# This block used to end "the right permanent fix is a design decision, NOT
# taken here: either give spire-server a PVC so its CA survives, or make a
# server restart explicitly wipe the agent's hostPath". The first option was
# chosen and implemented.
#
# d2-signalloom/infra/inf-bao/controllers/base/openbao-spire.yaml now declares a
# 1Gi ReadWriteOnce PersistentVolumeClaim `spire-server-data` mounted at
# data_dir, and the Deployment uses `strategy: Recreate` — a RollingUpdate
# Deployment holding an RWO volume deadlocks against its own upgrade, so the two
# are one change. Both halves are pinned by
# d2-signalloom/test/spire-server-durability.bats, whose assertions DERIVE the
# mount path from server.conf rather than restating it, so moving data_dir,
# keys_path or the sqlite connection_string out from under the volume fails the
# suite instead of silently un-persisting the CA.
#
# The server is therefore the durable side too, matching the agent: a restart
# keeps its CA, its JWT signing keys and its registration entries, and the
# agent's cached bundle stays valid. Verified on kind-osramp 2026-08-30 — trust
# bundle sha256 and both localauthority IDs byte-identical across a pod delete,
# 3/3 registration entries retained, agent Running at 0 restarts throughout, and
# the fe-signalloom SPIFFE→OpenBao positive proof green afterwards.
#
# ── Why the refusal below STAYS ────────────────────────────────────────────
#
# The recovery text is still correct and this still refuses rather than
# repairing, because the failure remains reachable:
#
#   * clusters built before this change, whose spire-server has no PVC;
#   * a cluster whose PVC was deleted or re-provisioned. The storage class is
#     rancher.io/local-path with a Delete reclaim policy and node-local storage,
#     so removing the PVC — or losing the node — destroys the CA exactly as
#     thoroughly as the container layer did;
#   * any future edit that moves data_dir out from under the mount.
#
# Clearing the agent directory still needs node access, which is `docker exec`
# on kind and `gcloud compute ssh` on GCP — there is no portable in-cluster way
# to do it that does not involve running a privileged pod, which is a poor trade
# in this repo. A recovery command that silently half-works is worse than one
# that refuses and says what to run. See also d2-agent-trust/AGENTS.md.
#
# ── MIGRATING AN EXISTING CLUSTER ONTO THE PVC ─────────────────────────────
#
# READ THIS BEFORE APPLYING THE PVC TO A RUNNING CLUSTER. The change is not
# free on the way in, and the cost is exactly the outage it prevents.
#
# A new PVC is an EMPTY volume. spire-server starting on it mints a fresh CA and
# an empty registration table, once — which strands the agent's hostPath cache
# on the old CA and deletes every entry. So a naive `kubectl apply` of this
# change TRIGGERS the failure on the way to preventing it, and on a cluster
# whose trust chain was hand-repaired that discards the repair.
#
# There are two honest routes. Pick deliberately; do not discover this.
#
# ── Route A: pre-seed the volume, zero CA change (what was done 2026-08-30) ──
#
# Copy the running server's data_dir into the PVC BEFORE spire-server ever
# mounts it. The CA never changes, so the agent never notices and no recovery is
# needed. The image is DISTROLESS — no shell, no tar — so `kubectl cp` and
# `kubectl exec ... tar` are both unavailable; the copy has to happen node-side.
#
#   1. locate the live data on the node (kind shown; GCP is the same via ssh):
#        CID=$(docker exec <node> crictl ps --name spire-server -o json \
#                | jq -r '.containers[0].id')
#        PID=$(docker exec <node> crictl inspect "$CID" | jq -r '.info.pid')
#        docker exec <node> cp -a /proc/$PID/root/run/spire/data/. /var/lib/spire-migrate/
#   2. VERIFY the copy before trusting it. sqlite is live and WAL-mode, so a
#      raw file copy can tear:  sqlite3 datastore.sqlite3 'PRAGMA integrity_check;'
#      (reading it also checkpoints the WAL into a single clean file, which is
#      the artefact you want to seed). Confirm the row counts too:
#        select count(*) from registered_entries;  select count(*) from ca_journals;
#   3. create ONLY the PVC, plus a throwaway pod that mounts it, so local-path
#      provisions the directory. WaitForFirstConsumer means the PVC does not
#      bind — and the node path does not exist — until something consumes it.
#   4. copy the verified data into that path node-side and `chown -R 1000:0`
#      (the SPIRE image runs as uid 1000; local-path provisions the dir 0777
#      root-owned, so this is belt-and-braces, not strictly required).
#   5. delete the throwaway pod, THEN apply the Deployment. The server comes up
#      on a populated volume with its original CA and entries.
#
# ── Route B: accept the one-time break, then recover ────────────────────────
#
# Simpler, and correct when the entries are reproducible from code — which on
# this lane they are. Apply the Deployment, then run the full recovery:
#
#   1. kubectl -n <ns> delete secret spire-agent-join-token --ignore-not-found
#   2. clear ${SPIRE_AGENT_DATA_HOSTPATH} ON THE NODE (see the recovery text in
#      assert_spire_agent_trusts_server below for the exact commands)
#   3. mint a fresh join token and recreate the Secret —
#      bootstrap_spire_agent_join_token() in scripts/demo-lifecycle.sh. Join
#      tokens are SINGLE-USE and every crash-loop restart burns one, so always
#      mint a new one rather than reusing.
#   4. re-register the workload entries —
#      register_spire_proof_identity() in scripts/demo-lifecycle.sh
#   5. re-run the OpenBao bootstrap, then sync_openbao_jwt_validation() in this
#      file. The CA is new, so OpenBao's jwt_validation_pubkeys snapshot is
#      stale and every SPIFFE login fails until it is re-synced.
#   6. restart the agent and assert with assert_spire_agent_trusts_server().
#
# `make demo-bao-up` (bao_up in scripts/demo-lifecycle.sh) performs steps 1 and
# 3-6 in that order. It CANNOT perform step 2 — that is the whole reason this
# file refuses rather than repairing — so running it without having cleared the
# node directory leaves the agent crash-looping on the same stale bundle, which
# is the state that produced 1528 restarts.
#
# ── Route B has a PREREQUISITE that is easy to miss ────────────────────────
#
# bao_up calls `wait_kustomization "$BAO_NAMESPACE" infra-configs` BEFORE it
# reaches register_spire_proof_identity. So if inf-bao/infra-controllers is not
# Ready, inf-bao/infra-configs never goes Ready either (it dependsOn it), bao_up
# blocks there, and the entries are never re-registered — the recovery stops
# half-done, with a fresh CA and an empty registration table.
#
# That is not hypothetical: it is the state the namespace was in on 2026-08-30,
# via the privilege-escalation deadlock described in
# d2-signalloom/infra/inf-bao/controllers/base/spire-openbao-sync-cronjob.yaml.
# Check `kubectl -n inf-bao get kustomization` is Ready BEFORE choosing Route B.
# If it is not, Route A is the only route that works, because it never needs to
# re-register anything.
#
# ── Status of that precondition ────────────────────────────────────────────
#
# The cascade that blocked it has been cleared in the repo. inf-bao carried FIVE
# independent defects, every one of which had never run and so was never
# reported, each masking the next:
#
#   1. RoleBinding authored in the slice -> privilege-escalation dry-run
#      deadlock, aborting the whole change set (fixed: RBAC moved to the
#      signalloom-spire-rbac ResourceSet);
#   2. openbao-agent-generic-role-setup passing map-typed fields as k=v ->
#      HTTP 400 (fixed: JSON on stdin);
#   3. spire-agent-swarm-entries-setup shelling out in a distroless image, with
#      a removed flag, at the wrong socket, behind error swallowing (fixed:
#      kubectl exec, outcome asserted);
#   4. both kubectl workloads pinned docker.io/bitnami/kubectl:1.31, a tag
#      Bitnami deleted -> ImagePullBackOff (fixed: bitnamilegacy);
#   5. no NetworkPolicy egress to kube-apiserver, so kubectl timed out against
#      10.96.0.1:443 (fixed: allow-kubectl-clients-apiserver-egress).
#
# Route B is therefore viable again ONCE THOSE ARE DEPLOYED — which means once
# the OCI artifact carries them. Until the artifact is republished, the live
# cluster still has the old manifests and Route B still stops half-done. Verify
# rather than assume: `kubectl -n inf-bao get kustomization infra-controllers`
# must be Ready=True before you rely on it.
SPIRE_AGENT_DATA_HOSTPATH="${SPIRE_AGENT_DATA_HOSTPATH:-/var/lib/spire-agent/data}"

_spire_agent_logs() {
  kubectl -n "$1" logs -l app.kubernetes.io/name=spire-agent --tail=80 2>/dev/null
}

# Has the agent actually attested to the server that is running NOW?
#
# Asserts the positive marker rather than the absence of an error: an agent that
# logs nothing at all has not attested either, and "no error yet" is exactly how
# a still-starting pod looks. Reads into a variable rather than piping into
# `grep -q`, which under pipefail can report 141 when the match succeeds early.
assert_spire_agent_trusts_server() {
  local namespace="$1" deadline logs
  deadline=$((SECONDS + ${DEMO_AGENT_ATTEST_TIMEOUT:-120}))
  while :; do
    logs="$(_spire_agent_logs "$namespace" || true)"
    grep -Fq 'Starting Workload and SDS APIs' <<<"$logs" && return 0
    ((SECONDS >= deadline)) && break
    sleep 2
  done

  if grep -Fq 'certificate signed by unknown authority' <<<"$logs"; then
    cat >&2 <<EOF
SPIRE agent is holding a stale trust bundle and cannot attest to this server.

Cause: spire-server was rebuilt with a NEW CA. The agent's data directory is a
hostPath, so it survived and still trusts the OLD CA. This is not recoverable by
re-running bao-up: it deletes the Secret and the pod but never clears the node
directory, so every replacement pod reloads the same stale bundle.

CHECK THIS FIRST. spire-server is supposed to be durable — it mounts the PVC
spire-server-data at its data_dir precisely so a restart cannot change the CA.
Seeing this message means that protection is absent or was bypassed:

  kubectl -n $namespace get pvc spire-server-data
  kubectl -n $namespace get deploy spire-server -o yaml | grep -A3 'name: data'

No PVC, or a "data" volume that is not persistentVolumeClaim-backed, means this
cluster predates the fix (or lost it) and is exhibiting the original defect. A
Bound PVC alongside a fresh CA means the VOLUME was replaced rather than the
pod: the storage class is local-path with a Delete reclaim policy and node-local
storage, so deleting the PVC or losing the node destroys the CA just as
thoroughly. Either way the agent recovery below is the same.

Recovery, in this order — the third step is the one bao-up cannot do for you:

  1. kubectl -n $namespace delete secret spire-agent-join-token --ignore-not-found
  2. kubectl -n $namespace delete pod -l app.kubernetes.io/name=spire-agent --wait=true
  3. clear ${SPIRE_AGENT_DATA_HOSTPATH} ON THE NODE:
       kind: docker exec <node> sh -c 'rm -rf ${SPIRE_AGENT_DATA_HOSTPATH}/*'
             (node name: kubectl get nodes -o name)
       GCP:  gcloud compute ssh <instance> --zone <zone> --command \\
               "sudo rm -rf ${SPIRE_AGENT_DATA_HOSTPATH}/*"
  4. re-run: make demo-bao-up

Join tokens are single-use, so every crash-loop restart burns one. Do not reuse
a token from a previous attempt; step 4 generates a fresh one.
EOF
  else
    cat >&2 <<EOF
SPIRE agent did not attest within ${DEMO_AGENT_ATTEST_TIMEOUT:-120}s: it never logged
"Starting Workload and SDS APIs", so no workload on this lane can obtain an SVID.

This is asserted positively on purpose — an agent that logs nothing has not
attested, and treating silence as success is how a dead identity plane reports
healthy. Inspect with:

  kubectl -n $namespace logs -l app.kubernetes.io/name=spire-agent --tail=80
  kubectl -n $namespace get pods -l app.kubernetes.io/name=spire-agent

If the logs mention "certificate signed by unknown authority", the agent is
holding a stale bundle from a rebuilt server; see
${SPIRE_AGENT_DATA_HOSTPATH} in d2-agent-trust/AGENTS.md.
EOF
  fi
  return 1
}

# The key ID SPIRE is signing JWT-SVIDs with RIGHT NOW.
#
# spire_jwt_svid_keys returns the whole validation SET, which across a rotation
# is deliberately more than one key. This narrows it to the single authority
# that actually signs, because the two answer different questions: a key missing
# from OpenBao is a pending outage, whereas the ACTIVE key missing from OpenBao
# is a current one. On 2026-08-14 nobody could tell those apart and the outage
# was attributed to an unrelated pod.
#
# ── Do NOT set `socket_path` in server.conf to make this reachable ─────────
#
# Every spire-server CLI call in this repo uses SPIRE's DEFAULT admin socket,
# /tmp/spire-server/private/api.sock — this file's readers, demo-lifecycle.sh's
# `token generate` and `entry create`, and pipeline stage 6e.
#
# While validating the oidc-discovery-provider sidecar on 2026-08-23 the obvious
# move was `socket_path = "/run/spire/private/api.sock"` in server.conf so the
# sidecar could share a volume there. It broke EVERY one of those calls at once
# with `dial unix /tmp/spire-server/private/api.sock: no such file or directory`,
# including the drift guard itself.
#
# The correct shape is to mount the shared emptyDir AT the default path and
# leave server.conf untouched — the sidecar gets its socket, the CLI keeps
# working, and the diff shrinks to the Deployment. If you find yourself
# "tidying" an explicit socket_path back in, this is what it costs.
#
# Lives here, beside the other SPIRE reads, rather than in the test that wants
# it: every kubectl in this seam belongs to this file. test/no-exec-probes-in-
# tests.bats enforces that, and the reason is not tidiness — a `kubectl exec`
# inside a test cannot distinguish "the property failed" from "the probe
# failed", which is how a distroless image once silently disarmed the cardvault
# auth test while it stayed green.
spire_active_jwt_authority_kid() {
  local namespace="$1" shown
  shown="$(kubectl -n "$namespace" exec deployment/spire-server -- \
    /opt/spire/bin/spire-server localauthority jwt show)" || return 1
  awk '/^Active JWT authority:/{f=1} f&&/Authority ID:/{print $3; exit}' <<<"$shown"
}

# base64(DER) for one specific SPIRE JWT-SVID key, selected by kid, in the same
# encoding as spire_jwt_svid_keys so the two are directly comparable.
spire_jwt_key_der_for_kid() {
  local namespace="$1" kid="$2" bundle x y
  bundle="$(kubectl -n "$namespace" exec deployment/spire-server -- \
    /opt/spire/bin/spire-server bundle show -format spiffe)" || return 1
  IFS=$'\t' read -r x y < <(jq -r --arg k "$kid" '
    .keys[] | select(.use == "jwt-svid" and .kid == $k) | [.x, .y] | @tsv' <<<"$bundle")
  [[ -n "$x" && -n "$y" ]] || {
    printf 'SPIRE bundle publishes no JWT-SVID key with kid %s\n' "$kid" >&2
    return 1
  }
  _spire_jwk_to_der_b64 "$x" "$y"
}

# Every key OpenBao will currently accept a JWT-SVID signature from, one per
# line, in the same encoding as spire_jwt_svid_keys.
openbao_jwt_validation_keys() {
  local namespace="$1" token="$2" config encoded pem
  local -a encoded_pems=()
  config="$(kubectl -n "$namespace" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$token" \
    bao read -format=json auth/jwt/config)" || return 1
  # @base64 per element: a PEM spans several lines, so a bare `[]` would split
  # one key across several array entries and compare nothing meaningful.
  mapfile -t encoded_pems < <(jq -r '(.data.jwt_validation_pubkeys // [])[] | @base64' <<<"$config")
  for encoded in ${encoded_pems[@]+"${encoded_pems[@]}"}; do
    pem="$(printf '%s' "$encoded" | base64 -d)"
    printf '%s' "$pem" | openssl pkey -pubin -outform DER 2>/dev/null | base64 -w0 || return 1
    printf '\n'
  done
}

# Point OpenBao at the keys SPIRE is signing with now.
#
# Uses command substitution to propagate spire_jwt_svid_keys exit status. The
# previous `mapfile < <(cmd)` form swallowed failures: mapfile always returns 0
# regardless of cmd's exit, so a failed kubectl left keys empty, the emptiness
# guard said "refusing to write an empty set" — correct refusal, but the error
# message named the symptom (empty) not the cause (SPIRE unreachable).
sync_openbao_jwt_validation() {
  local namespace="$1" token="$2" key_out key pem csv i
  local -a keys=() pems=()
  key_out="$(spire_jwt_svid_keys "$namespace")" || {
    printf 'sync_openbao_jwt_validation: cannot read SPIRE JWT-SVID keys — aborting before writing to OpenBao\n' >&2
    printf 'Consequence: OpenBao keeps its current jwt_validation_pubkeys (stale keys are better than no keys)\n' >&2
    printf 'Recovery: fix the SPIRE read above, then re-run sync_openbao_jwt_validation or make demo-bao-up\n' >&2
    return 1
  }
  [[ -n "$key_out" ]] || {
    printf 'sync_openbao_jwt_validation: SPIRE returned successfully but produced no keys — refusing to write an empty jwt_validation_pubkeys to OpenBao\n' >&2
    printf 'Consequence: every SPIFFE login would fail immediately with "no known key successfully validated the token signature"\n' >&2
    return 1
  }
  mapfile -t keys <<<"$key_out"
  i=0
  for key in "${keys[@]}"; do
    [[ -n "$key" ]] || continue
    pem="$(_der_b64_to_pem "$key")" || {
      printf 'sync_openbao_jwt_validation: PEM conversion failed for key %d of %d — is openssl installed and working?\n' "$((i+1))" "${#keys[@]}" >&2
      return 1
    }
    pems+=("$pem")
    ((i++))
  done
  ((${#pems[@]} > 0)) || {
    printf 'sync_openbao_jwt_validation: all %d keys from SPIRE were empty after filtering — refusing to write\n' "${#keys[@]}" >&2
    return 1
  }
  printf -v csv '%s,' "${pems[@]}"
  csv="${csv%,}"
  kubectl -n "$namespace" exec deployment/openbao -- env \
    BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$token" \
    bao write auth/jwt/config jwt_validation_pubkeys="$csv" || {
    printf 'sync_openbao_jwt_validation: OpenBao refused the key write — check BAO_TOKEN validity and openbao pod health\n' >&2
    printf 'Recovery: kubectl -n %s exec deployment/openbao -- env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=<token> bao status\n' "$namespace" >&2
    return 1
  }
  printf 'sync_openbao_jwt_validation: wrote %d JWT validation key(s) to OpenBao auth/jwt/config\n' "${#pems[@]}"
}

# The gate. Both sides are derived from the artefacts that actually decide —
# SPIRE's live bundle and OpenBao's live config — so neither can be satisfied by
# a hardcoded expectation that has quietly stopped being true.
#
# Binding assertions alone could not catch this: bound_subject, bound_audiences
# and the SPIRE selectors were all still exactly right while every login failed.
assert_openbao_accepts_spire_jwt_keys() {
  local namespace="$1" token="$2" key held found spire_out bao_out
  local -a spire_keys=() bao_keys=()
  # `mapfile -t arr < <(cmd) || return 1` reports MAPFILE's status, never cmd's.
  # mapfile succeeds having read zero lines, so a failed kubectl left spire_keys
  # empty, the membership loop below never executed, and this function returned
  # 0 — announcing "OpenBao accepts every key SPIRE publishes" having read
  # NEITHER side. Reproduced 2026-08-23 with KUBECONFIG=/nonexistent: this
  # assert passed against no cluster at all.
  #
  # That is the same defect scripts/check-flux-substitution.sh was fixed for
  # (see its note in scripts/ci/vm-pipeline.sh), reappearing in the one assert
  # that exists to catch silent identity-plane failure. It mattered here more
  # than it did there: this function was about to become a pipeline stage, and a
  # stage that cannot fail is worse than an absent one because it reads as
  # coverage.
  #
  # Command substitution DOES propagate status, and both readers already
  # `|| return 1` on a failed kubectl, so this checks each read before comparing
  # anything. The emptiness guards are belt-and-braces: `mapfile <<<""` yields
  # one empty element, which the `-n` filter below would skip straight back into
  # a vacuous pass.
  spire_out="$(spire_jwt_svid_keys "$namespace")" || return 1
  bao_out="$(openbao_jwt_validation_keys "$namespace" "$token")" || return 1
  [[ -n "$spire_out" ]] || {
    printf 'refusing to compare: SPIRE returned no JWT-SVID keys\n' >&2
    return 1
  }
  [[ -n "$bao_out" ]] || {
    printf 'OpenBao holds NO JWT validation keys at all: auth/jwt/config was never synced or has been wiped, and every SPIFFE login fails\n' >&2
    return 1
  }
  mapfile -t spire_keys <<<"$spire_out"
  mapfile -t bao_keys <<<"$bao_out"
  for key in ${spire_keys[@]+"${spire_keys[@]}"}; do
    [[ -n "$key" ]] || continue
    found=false
    for held in ${bao_keys[@]+"${bao_keys[@]}"}; do
      [[ "$held" == "$key" ]] && { found=true; break; }
    done
    [[ "$found" == true ]] && continue
    printf 'OpenBao cannot validate the JWT-SVIDs SPIRE is signing now: SPIRE publishes %d JWT-SVID key(s), OpenBao holds %d, and at least one SPIRE key is absent from auth/jwt/config\n' \
      "${#spire_keys[@]}" "${#bao_keys[@]}" >&2
    printf 'SPIRE rotated its JWT signing key and OpenBao still holds the pre-rotation snapshot; every SPIFFE login fails with "no known key successfully validated the token signature" until the identity plane is re-synced\n' >&2
    return 1
  done
}
