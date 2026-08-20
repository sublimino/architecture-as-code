#!/usr/bin/env bash
#
# Signal Loom demo VM bootstrap.
#
# Runs once, as root, via metadata_startup_script. Installs the prerequisites
# for the Kind-based Signal Loom demo — Docker, kind, kubectl — and stops. It
# deliberately does NOT deploy the demo: that is the pipeline's job, and a
# startup script that also deploys is a startup script nobody can re-run.
#
# CONTAINS NO CREDENTIALS, BY CONSTRUCTION. The instance authenticates to
# Google APIs through its attached service account via the metadata server.
# Anything this script needs from Secret Manager it fetches at runtime under
# that identity. A literal here would be readable by anyone with
# compute.instances.get on the project, because startup scripts are stored in
# instance metadata in plain text.
#
# That rule is now load-bearing rather than aspirational: fetch_tailscale_authkey
# resolves the Tailscale auth key from Secret Manager at boot, under the attached
# service account, using a token the metadata server mints on the spot. What the
# instance metadata carries is the NAME of the secret. Nothing here, and nothing
# in Terraform state, holds the key itself.
#
# Tailscale is OPTIONAL and off unless the instance carries
# signalloom-tailscale-enabled=TRUE. It is access plumbing, not deployment: it
# joins the node to a tailnet and stops. Every failure path in that stage logs
# and continues, because a VM that will not boot without an optional feature's
# secret is worse than a VM without the feature.
#
# Egress note: with the network module's defaults this script CANNOT reach
# download.docker.com or the Kubernetes release servers, because public HTTPS
# egress is denied until an operator names destinations in
# egress_public_https_destinations. That failure is intentional and loud. See
# terraform/modules/network/README.md.

set -euo pipefail

# ── Toolchain pins ───────────────────────────────────────────────────────────
#
# THESE MUST MATCH scripts/ci/install-ci-tools.sh AND scripts/setup.sh.
# test/terraform-toolchain-pins.bats enforces that by DERIVING all three sets
# from the files themselves and failing on any disagreement — it does not carry
# a hand-written copy of today's numbers, because a fourth copy of a version
# string is the same defect one file further along.
#
# A shared constants file is not available to this script and that is not an
# oversight: this file is delivered as `metadata_startup_script` and runs before
# any repository exists on the instance, so it cannot source anything from the
# tree. Duplication is forced; what is NOT forced is the duplication being
# unchecked. The test is the single source of truth's enforcement mechanism.
#
# ─── Why these two lines were wrong, and what it cost ───────────────────────
#
# kind was pinned here at v0.24.0 while install-ci-tools.sh pinned 0.29.0 and
# setup.sh pinned v0.29.0 — one outlier against two that already agreed. This
# script installs 0.24.0 at boot as root; the pipeline then detects the mismatch
# and tries to upgrade, and THAT is what triggered the install failure on
# sl-demo-2-vm (see the long note above install_binary in install-ci-tools.sh —
# curl could not open the root-owned file this script had created). The two
# defects were only reachable together.
#
# NOTE THE `v`. install-ci-tools.sh stores the bare number and adds the prefix
# at the URL; this file and setup.sh store it with the prefix. The comparison in
# the test normalises it, because "0.29.0" != "v0.29.0" is exactly the kind of
# difference that makes a divergence test look green while the tools differ.
#
# kubectl WAS NOT PINNED HERE AT ALL. It resolved
# https://dl.k8s.io/release/stable.txt at boot, so the version installed on any
# given VM was whatever Kubernetes had released that morning: not reproducible
# between two VMs built a week apart, and an unpinned supply-chain intake on a
# machine whose entire demonstration subject is supply-chain posture. It is now
# pinned to the same version install-ci-tools.sh and setup.sh use, which also
# means the pipeline's version check no-ops instead of reinstalling.
readonly KIND_VERSION="v0.29.0"
readonly KUBECTL_VERSION="v1.33.2"
readonly LOG_TAG="signalloom-bootstrap"
readonly MARKER="/var/lib/signalloom/.bootstrapped"
readonly METADATA_ROOT="http://169.254.169.254/computeMetadata/v1"

# Written when this node joins the tailnet under a name that is NOT the one it
# asked for, and REMOVED on every boot that gets the right name. The path is
# part of the contract with scripts/gcp-tf/demo-up.sh, which reads it in
# `status` and `ts-status` and reports a mismatch as a FAILURE; it is stated in
# docs/gcp-demo/RUNBOOK.md § "The demo URL drifted".
#
# A file rather than a log line because the log is on the VM's serial console
# and nothing reads it. The whole failure this guards against is silent name
# drift, so the signal has to survive until somebody asks a question.
#
# CONTAINS NO KEY MATERIAL, and that is asserted by
# test/terraform-ts-stable-node-name.bats rather than left to good intentions.
readonly TS_NAME_MARKER="/var/lib/signalloom/tailscale-name-mismatch"

# The shutdown-time logout unit. See install_tailscale_logout_unit.
readonly TS_LOGOUT_UNIT_NAME="signalloom-tailscale-logout.service"
readonly TS_LOGOUT_UNIT="/etc/systemd/system/${TS_LOGOUT_UNIT_NAME}"

log() {
  echo "[${LOG_TAG}] $*"
  logger -t "$LOG_TAG" -- "$*" || true
}

die() {
  log "FATAL: $*"
  exit 1
}

# Downloads a file and verifies it against the publisher's own checksum sidecar.
# No checksum literal lives in this script: a pinned hash here goes stale at
# the next version bump and gets deleted rather than updated, which is how
# verification quietly disappears.
#
# The sidecar suffix is an argument because the two publishers disagree:
# dl.k8s.io serves "<artifact>.sha256", the kind releases serve
# "<artifact>.sha256sum". Hardcoding either one 404s on the other, and a 404 on
# the checksum is exactly the case that must abort rather than degrade.
fetch_verified() {
  local url="$1" dest="$2" sum_suffix="${3:-.sha256}" workdir
  workdir="$(mktemp -d)"

  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
    --output "${workdir}/payload" "$url" \
    || die "download failed: ${url}"

  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
    --output "${workdir}/payload.sum" "${url}${sum_suffix}" \
    || die "checksum download failed: ${url}${sum_suffix}"

  # Both publishers emit either "<hash>" or "<hash>  <filename>". Stripping all
  # whitespace and taking the leading 64 hex characters handles both.
  local expected actual
  expected="$(tr -d '[:space:]' <"${workdir}/payload.sum" | cut -c1-64)"
  actual="$(sha256sum "${workdir}/payload" | cut -d' ' -f1)"

  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] \
    || die "checksum sidecar for ${url} did not contain a sha256 digest"

  [[ "$expected" == "$actual" ]] \
    || die "checksum mismatch for ${url}: expected ${expected}, got ${actual}"

  install -m 0755 "${workdir}/payload" "$dest"
  rm -rf "$workdir"
  log "installed ${dest}"
}

# Reads one instance metadata attribute. Prints nothing and returns non-zero
# when the key is absent, which is how an optional feature stays optional.
#
# --fail matters: without it curl prints the metadata server's 404 body to
# stdout and exits 0, so an absent key returns the literal text of an error page
# as though it were the value. That reads as a configured-but-wrong setting
# rather than as an unset one.
metadata_attr() {
  curl --fail --silent --show-error \
    --header "Metadata-Flavor: Google" \
    "${METADATA_ROOT}/instance/attributes/$1" 2>/dev/null
}

# The prerequisites the pipeline cannot bootstrap itself, and nothing more.
#
# Every entry below is needed BEFORE scripts/ci/install-ci-tools.sh can run,
# which is the first thing the pipeline invokes. Each is here because something
# in the repo demonstrably calls it, not because it seemed likely:
#
#   git             install-ci-tools.sh installs bats by `git clone`, and
#                   vm-pipeline.sh runs `git init -q` so Kustomize will resolve
#                   the tree as a repository. Neither can install git first.
#   make            the pipeline drives the demo entirely through make targets
#                   (`make ci-tools`, `make demo-signalloom-up`). A VM with no
#                   make has nothing to run.
#   ca-certificates every fetch below and in the installer is HTTPS.
#   curl            fetch_verified, install-ci-tools.sh, and the Go tarball.
#   gnupg           dearmours the Docker apt key further down.
#   apt-transport-https  the Docker apt source is HTTPS.
#
# Deliberately NOT here, with the ACTUAL provider named in each case rather than
# assumed — every claim below was checked against the file it names:
#
#   jq            scripts/setup.sh:100, via fetch_bin from the jq releases page.
#   python3       scripts/ci/install-ci-tools.sh, apt, near the end.
#   unzip         scripts/ci/install-ci-tools.sh, apt, on demand for bun's zip.
#   node/bun/uv   scripts/ci/install-ci-tools.sh, pinned + checksum-verified.
#   gcc/g++       NOTHING INSTALLS THEM, and nothing needs them. This list used
#                 to say they "belong to scripts/setup.sh"; setup.sh apt-installs
#                 only skopeo. There is no CGO_ENABLED anywhere in the repo and
#                 every Go tool fetched by `go install` here is pure Go, so the
#                 absence is correct — but the stated reason was not, and an
#                 incorrect reason is what makes the next person go looking in
#                 the wrong file.
#
# Adding any of them here would move the provisioning/deployment line without
# moving the responsibility, and this script's whole contract is that it stops
# at prerequisites.
#
# THIS LIST PREVIOUSLY CLAIMED "node arrives with the Playwright setup". It does
# not, and the claim cost three separate forty-minute runs to disprove one tool
# at a time. The Playwright step in scripts/ci/vm-pipeline.sh RUNS `npx
# playwright install chrome` — it consumes npx and has never provided it. The v1
# CI VM's scripts/ci/vm-startup.sh installs node, bun and uv; this script is v1's
# replacement for the demo lane and silently dropped all three, so every fresh
# VM failed on `npx: not found`, then `bun: command not found`, then uv. They are
# now installed, pinned and checksum-verified, in install-ci-tools.sh beside the
# other toolchain pins where test/terraform-toolchain-pins.bats can see them.
#
# Runs unconditionally rather than inside install_docker. It used to be folded
# into that function, which early-returns when docker is already present — so
# on any image shipping docker, curl and gnupg were silently never installed
# and fetch_verified failed at the first download. The marker file at the top
# of main() is what makes re-running cheap; a second guard inside a function
# only makes it incomplete.
install_base_packages() {
  log "installing base prerequisites"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    ca-certificates curl gnupg apt-transport-https git make
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "docker already present, skipping"
    return 0
  fi

  log "installing docker"
  export DEBIAN_FRONTEND=noninteractive

  install -m 0755 -d /etc/apt/keyrings

  # The distribution is DERIVED from the running image, never assumed. This was
  # hardcoded to "debian" while the module's image_family default moved to
  # ubuntu-2404-lts, and a hardcoded distro here does not fail loudly: apt
  # simply finds no candidate for the codename and the whole docker install
  # degrades into "Unable to locate package docker-ce" — which reads as a
  # network or mirror problem rather than as a repository pointing at the wrong
  # operating system.
  local distro codename
  # shellcheck source=/dev/null  # provided by the base image, not by this repo
  distro="$(. /etc/os-release && echo "$ID")"
  # shellcheck source=/dev/null  # provided by the base image, not by this repo
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

  case "$distro" in
    debian | ubuntu) ;;
    *) die "unsupported base image '${distro}': docker packages are published for debian and ubuntu only" ;;
  esac

  curl --fail --silent --show-error --location \
    "https://download.docker.com/linux/${distro}/gpg" \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${distro} ${codename} stable" \
    >/etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
}

install_kind() {
  if command -v kind >/dev/null 2>&1; then
    log "kind already present, skipping"
    return 0
  fi
  log "installing kind ${KIND_VERSION}"
  fetch_verified \
    "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64" \
    /usr/local/bin/kind \
    ".sha256sum"
}

install_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    log "kubectl already present, skipping"
    return 0
  fi

  # PINNED, not resolved. This used to fetch dl.k8s.io/release/stable.txt at
  # boot and install whatever it named, which meant two VMs built a week apart
  # ran different kubectl versions with nothing recording why — and it made the
  # pipeline's pinned check reinstall on every machine that drifted. See the
  # KUBECTL_VERSION note at the top of this file.
  log "installing kubectl ${KUBECTL_VERSION}"
  fetch_verified \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    /usr/local/bin/kubectl
}

# ---------------------------------------------------------------------------
# Tailscale
#
# Optional, off unless the instance carries signalloom-tailscale-enabled=TRUE.
# Every failure path below LOGS AND CONTINUES rather than aborting: a VM that
# fails to boot because an optional feature's secret is missing is strictly
# worse than a VM without that feature, and the estate's actual bring-up does
# not depend on the tailnet in any way.
#
# ─── Why nothing here uses `|| die` and nothing relies on errexit ───────────
#
# `set -e` is active, so an unchecked failure anywhere in this function kills
# the whole bootstrap before the marker is written. The tempting fixes are both
# wrong: `install_tailscale || true` at the call site DISABLES errexit for the
# entire function body (bash suppresses it inside any command that is part of a
# condition or a `||` list, and that suppression propagates into subshells), so
# every later step would run on the wreckage of an earlier one. Instead every
# fallible command carries its own explicit `|| { log; return 0; }`. That is
# deterministic and does not depend on errexit semantics at all.
#
# ─── Where the auth key comes from, and where it is NOT ─────────────────────
#
# The key is fetched HERE, at runtime, from Secret Manager, using the token the
# metadata server mints for this instance's own attached service account. It is
# not in this file, not in instance metadata, and not in Terraform state. What
# metadata carries is the NAME of the secret; resolving that name requires
# roles/secretmanager.secretAccessor on that one secret, which modules/compute
# grants to the runtime service account and to nothing else.
#
# The key is minted reusable + ephemeral + pre-approved. Ephemeral means the
# node is eventually reaped after it goes offline — measured at 47-100 minutes,
# which is a long-stop and not a mechanism. See the note above
# bring_tailscale_up for why the name is released explicitly instead.
#
# ─── Egress requirements, stated because they are easy to get wrong ─────────
#
#   * secretmanager.googleapis.com — TCP 443 to the restricted Private Google
#     Access VIP. Already permitted by allow_egress_google_apis AND resolved to
#     the VIP by the private DNS zone. Both halves are needed; see the long
#     comment in modules/network/main.tf about the half that was once missing.
#   * pkgs.tailscale.com — TCP 443 to the public internet, which is DENIED
#     unless the environment names destinations in
#     egress_public_https_destinations. If it does not, the apt install below
#     fails, this function logs and returns, and the VM boots without Tailscale.
#   * 41641/udp and 3478/udp — optional. Without them Tailscale still connects,
#     relaying through DERP over TCP 443 rather than negotiating a direct path.
install_tailscale() {
  local enabled secret_id tag node_name want_ssh
  enabled="$(metadata_attr signalloom-tailscale-enabled)" || enabled=""

  if [[ "$enabled" != "TRUE" ]]; then
    log "tailscale is not enabled for this instance, skipping"
    return 0
  fi

  # Each of these is written by Terraform whenever the feature is on, so a
  # missing one means the metadata and this script have drifted apart. That is
  # worth saying out loud rather than defaulting around.
  secret_id="$(metadata_attr signalloom-tailscale-secret-id)" || secret_id=""
  tag="$(metadata_attr signalloom-tailscale-tag)" || tag=""
  node_name="$(metadata_attr signalloom-tailscale-hostname)" || node_name=""
  want_ssh="$(metadata_attr signalloom-tailscale-ssh)" || want_ssh="FALSE"

  if [[ -z "$secret_id" || -z "$tag" || -z "$node_name" ]]; then
    log "WARNING: tailscale is enabled but its metadata is incomplete"
    log "WARNING: secret-id='${secret_id}' tag='${tag}' hostname='${node_name}'"
    log "WARNING: continuing without tailscale"
    return 0
  fi

  install_tailscale_package || return 0

  local authkey
  authkey="$(fetch_tailscale_authkey "$secret_id")" || return 0

  bring_tailscale_up "$authkey" "$tag" "$node_name" "$want_ssh"
}

# Installs the tailscale package from the publisher's own apt repository.
#
# Deliberately NOT fetch_verified: that function exists for a single binary
# published alongside a checksum sidecar, and Tailscale publishes neither a
# standalone binary nor a sidecar for the path taken here. What replaces it is
# strictly stronger — apt verifies every package against the signing key pinned
# in signed-by, so a tampered mirror is rejected by apt itself rather than by a
# hash we happened to remember to check. This is the same shape as
# install_docker above, on purpose: two apt repositories configured two
# different ways is how one of them ends up unverified.
install_tailscale_package() {
  if command -v tailscale >/dev/null 2>&1; then
    log "tailscale already present, skipping install"
    return 0
  fi

  local distro codename
  # The distribution is DERIVED from the running image, never assumed — the
  # same rule and the same measured failure as install_docker. Tailscale
  # publishes separate repositories for debian and ubuntu, and a hardcoded one
  # does not fail loudly: apt finds no candidate and reports "Unable to locate
  # package tailscale", which reads as a network problem.
  # shellcheck source=/dev/null  # provided by the base image, not by this repo
  distro="$(. /etc/os-release && echo "$ID")"
  # shellcheck source=/dev/null  # provided by the base image, not by this repo
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

  case "$distro" in
    debian | ubuntu) ;;
    *)
      log "WARNING: tailscale packages are published for debian and ubuntu only"
      log "WARNING: this image reports '${distro}'; continuing without tailscale"
      return 1
      ;;
  esac

  log "installing tailscale for ${distro} ${codename}"
  install -m 0755 -d /usr/share/keyrings

  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
    --output /usr/share/keyrings/tailscale-archive-keyring.gpg \
    "https://pkgs.tailscale.com/stable/${distro}/${codename}.noarmor.gpg" \
    || {
      log "WARNING: could not fetch the tailscale signing key"
      log "WARNING: public HTTPS egress to pkgs.tailscale.com is denied unless"
      log "WARNING: the environment names it in egress_public_https_destinations"
      return 1
    }
  chmod a+r /usr/share/keyrings/tailscale-archive-keyring.gpg

  # Written by hand rather than fetched from the publisher's .list URL. The
  # fetched file is a convenience that hardcodes the same three fields; writing
  # them here means the signed-by path is visible in this script, where it can
  # be reviewed, rather than in a file that arrives over the network.
  echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/${distro} ${codename} main" \
    >/etc/apt/sources.list.d/tailscale.list

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || {
    log "WARNING: apt-get update failed after adding the tailscale repository"
    return 1
  }
  apt-get install -y -qq --no-install-recommends tailscale || {
    log "WARNING: could not install the tailscale package"
    return 1
  }

  systemctl enable --now tailscaled || {
    log "WARNING: tailscaled did not start"
    return 1
  }
}

# Resolves the auth key from Secret Manager under this instance's own identity.
# Prints the key on stdout; logs and returns non-zero on every failure.
#
# The REST API rather than gcloud: gcloud is not guaranteed present on the base
# image, and adding it as a prerequisite for an optional feature would move the
# provisioning line for every environment including the ones that never enable
# this. curl is already a prerequisite for everything else here.
fetch_tailscale_authkey() {
  local secret_id="$1" project bearer response payload

  project="$(curl --fail --silent --show-error \
    --header "Metadata-Flavor: Google" \
    "${METADATA_ROOT}/project/project-id" 2>/dev/null)" || {
    log "WARNING: could not read the project id from the metadata server"
    return 1
  }

  # The instance's own access token, minted by the metadata server for the
  # attached service account. Nothing long-lived is stored anywhere.
  bearer="$(curl --fail --silent --show-error \
    --header "Metadata-Flavor: Google" \
    "${METADATA_ROOT}/instance/service-accounts/default/token" 2>/dev/null \
    | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')" || bearer=""

  if [[ -z "$bearer" ]]; then
    log "WARNING: the metadata server issued no access token for this instance"
    return 1
  fi

  response="$(curl --fail --silent --show-error --retry 3 --retry-delay 2 \
    --header "Authorization: Bearer ${bearer}" \
    "https://secretmanager.googleapis.com/v1/projects/${project}/secrets/${secret_id}/versions/latest:access" \
    2>/dev/null)" || {
    log "WARNING: could not read secret '${secret_id}' from Secret Manager"
    log "WARNING: the instance service account needs roles/secretmanager.secretAccessor"
    log "WARNING: on that secret, and the secret must have at least one version"
    log "WARNING: continuing without tailscale"
    return 1
  }

  # The payload is base64 in a JSON field. Parsed with sed rather than jq
  # because jq is deliberately not a prerequisite of this script — see the
  # prerequisites comment above install_base_packages.
  payload="$(printf '%s' "$response" \
    | sed -n 's/.*"data"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | base64 -d 2>/dev/null | tr -d '[:space:]')"

  # Shape check, and it is not decoration. A changed response shape, a truncated
  # read or a sed that matched the wrong field all produce a NON-EMPTY string
  # that `tailscale up` would accept and reject remotely — so the observable
  # symptom would be "the node never joined", identical to a missing grant.
  # Refusing anything that is not a Tailscale key turns that into one clear line.
  if [[ "$payload" != tskey-* ]]; then
    log "WARNING: secret '${secret_id}' does not hold a tailscale auth key"
    log "WARNING: expected a value beginning 'tskey-'; continuing without tailscale"
    return 1
  fi

  printf '%s' "$payload"
}

# Brings the node up non-interactively.
#
# ─── The name is the product, and it is not guaranteed by --hostname ────────
#
# THIS COMMENT USED TO CLAIM the rebuilt VM "reclaims sl-demo-1 rather than
# accumulating sl-demo-1-2, sl-demo-1-3". Nothing implemented that, and the
# claim is why the drift went unnoticed: a comment asserting an invariant the
# code does not hold reads as a guarantee to everyone downstream of it.
#
# Measured on 2026-08-18, after sl-demo-1 was destroyed and rebuilt:
#
#   HostName=sl-demo-1  DNSName=sl-demo-1.taild4da3.ts.net.    online=false
#   HostName=sl-demo-1  DNSName=sl-demo-1-1.taild4da3.ts.net.  online=true
#
# --hostname IS honoured — HostName is identical on both records. What drifts is
# the MagicDNS name, because `terraform destroy` removes the GCP instance and
# NOTHING removes the tailnet device record. The corpse still owns the name, so
# the new node is assigned the next free suffix. The suffix is a function of how
# many corpses exist, so the URL moves further on every rebuild.
#
# That matters here specifically because the whole point of this access plane is
# a URL that can be sent to somebody BEFORE the VM has booted. A name that is
# only knowable after the fact is not a name you can put in a calendar invite.
#
# ─── The two mechanisms that keep the name, and the one that catches it ─────
#
#   1. Removal on teardown, which is the real fix. Primary path: demo-up.sh
#      runs `tailscale logout` over SSH before `terraform destroy` (wired into
#      the gcp-tf-destroy target). Backstop for hard kills: the systemd unit
#      installed by install_tailscale_logout_unit below. Measured: the device
#      record is GONE within 5 seconds of the logout — removed outright, not
#      left as a logged-out husk still holding the name. A subsequent
#      `tailscale up --hostname=<name>` on the SAME key reclaims the name and
#      the tag exactly.
#   2. The ephemeral auto-reap, as a LONG-STOP only. Measured at more than 47
#      and less than 100 minutes after disconnect — correct, and useless
#      against a rebuild cadence measured in minutes. It covers the teardowns
#      1 cannot reach (preemption, console deletion, a destroy run elsewhere),
#      an hour later. Anything that treats it as the mechanism is waiting.
#   3. assert_tailscale_node_name, below, which is what turns a failure of 1
#      and 2 from silent drift into a loud, durable signal. On a fast rebuild
#      it is the ONLY thing that fires, because 2 has not had time to.
#
# A random or hex suffix was considered for the hostname and REJECTED. It fixes
# collision and destroys the property being defended: the name would be unique
# and unpredictable, when what is needed is a name that is stable and knowable
# in advance.
bring_tailscale_up() {
  local authkey="$1" tag="$2" node_name="$3" want_ssh="$4"
  local args=()

  # --advertise-tags makes the node owned by the tailnet ACL rather than by the
  # user whose key created it. An untagged node inherits that user's access and
  # disappears from the tailnet when their account does.
  args+=("--advertise-tags=${tag}")

  # Deterministic, derived from the environment key by Terraform. Requested, not
  # guaranteed — see the long note above. assert_tailscale_node_name checks what
  # was actually granted.
  args+=("--hostname=${node_name}")

  # ─── --accept-dns=false is load-bearing, not tidiness ────────────────────
  #
  # Accepting MagicDNS rewrites /etc/resolv.conf. This VM's resolver is the
  # metadata server, and the VPC private zone is what points googleapis.com at
  # the restricted Private Google Access VIP. Replace the resolver and
  # googleapis.com resolves PUBLICLY again — at which point deny_all_egress
  # correctly refuses the public address and the estate fails with
  # "dial tcp 172.217.x.x:443: i/o timeout", exactly the failure documented at
  # length in modules/network/main.tf. That failure reads as an over-strict
  # firewall and has nothing to do with the firewall.
  args+=("--accept-dns=false")

  # Off unless the environment asked for it. The argument for and against lives
  # beside var.tailscale_ssh_enabled in modules/compute/variables.tf; the short
  # version is that it adds a second authorisation system that GCP IAM and the
  # GCP audit log cannot see.
  if [[ "$want_ssh" == "TRUE" ]]; then
    log "enabling tailscale ssh on this node"
    args+=("--ssh")
  fi

  # --auth-key last and passed by value, never echoed. `set -x` is not enabled
  # anywhere in this script for exactly this reason.
  tailscale up --auth-key="$authkey" "${args[@]}" || {
    log "WARNING: 'tailscale up' failed; continuing without tailscale"
    return 0
  }

  # Install the backstop BEFORE asserting the name. The two are independent: a
  # node that came up under the wrong name still has a device record that must
  # be released on shutdown, and skipping the unit on the mismatch path would
  # leave exactly the corpse that caused the mismatch in the first place.
  install_tailscale_logout_unit

  assert_tailscale_node_name "$node_name" || return 1

  log "tailscale is up as ${node_name} (${tag})"
}

# This node's own MagicDNS name, as the tailnet reports it. Empty when it cannot
# be read, which is a distinct outcome from a mismatch and is treated as one.
#
# --peers=false is load-bearing rather than tidiness. EVERY peer object carries
# its own "DNSName" field, so against a full status document a first-match
# extraction returns whichever node the daemon happened to serialise first —
# which on a healthy tailnet is somebody else's laptop, and the resulting
# "mismatch" would name a machine that has nothing to do with this one.
#
# grep -o then cut, rather than sed: a `sed -n 's/.*"DNSName".*/\1/p'` is greedy
# and silently binds to the LAST occurrence, so it would keep working right up
# until the day --peers=false is removed and then be wrong without changing.
# Taking the FIRST match explicitly is the same cost and does not have that
# property.
#
# No jq anywhere, for the reason stated above fetch_tailscale_authkey: jq is
# deliberately not a prerequisite of this script.
tailscale_self_dnsname() {
  tailscale status --json --peers=false 2>/dev/null |
    tr -d '\n' |
    grep -o '"DNSName"[[:space:]]*:[[:space:]]*"[^"]*"' |
    head -n 1 |
    sed 's/.*"\([^"]*\)"$/\1/'
}

# Did the tailnet give us the name we asked for?
#
# Logged at ERROR, not WARNING. This file's convention is that WARNING means
# degradation — a feature that did not come up, on a VM that is otherwise fine.
# This is not degradation. Tailscale is fully working; it is working under a
# name nobody can predict, which means every URL handed out in advance is wrong.
# The estate is up and the deliverable is broken, and those two need different
# words or the second one is never read.
#
# NEVER falls back to accepting the suffixed name. Accepting it would make the
# node reachable and the drift permanent, which is how sl-demo-1-1 was reached
# in the first place.
assert_tailscale_node_name() {
  local want="$1" got label

  got="$(tailscale_self_dnsname)"

  if [[ -z "$got" ]]; then
    log "ERROR: joined the tailnet but could not read this node's MagicDNS name"
    log "ERROR: 'tailscale status --json --peers=false' returned no DNSName"
    log "ERROR: the name this node answers to is UNVERIFIED; treat any URL"
    log "ERROR: derived from '${want}' as unconfirmed"
    write_ts_name_marker "$want" "(unreadable)"
    return 1
  fi

  # Trailing-dot safe. The API returns a correct FQDN — "sl-demo-1.tailnet.ts.net."
  # — and the trailing dot is part of that correctness, not a defect to work
  # around. Comparing the raw string to a short hostname fails on every healthy
  # node, so this is the difference between a guard and a permanent false alarm.
  got="${got%.}"

  # The first label is what matters: the suffix belongs to the tailnet, not to
  # this node, and hardcoding it here would be the "no literal FQDN" rule broken
  # in the one place it is easiest to break it.
  label="${got%%.*}"

  if [[ "$label" == "$want" ]]; then
    # Clear a marker from an EARLIER boot. Without this a single historical
    # mismatch makes a healthy VM report failure forever, and a guard that
    # cannot go back to green is a guard people learn to ignore.
    rm -f "$TS_NAME_MARKER"
    log "tailscale node name verified: ${got}"
    return 0
  fi

  log "ERROR: tailscale assigned a different name than the one requested"
  log "ERROR: requested '${want}', got '${label}' (fqdn ${got})"
  log "ERROR: a stale device record still owns '${want}' in this tailnet."
  log "ERROR: Nothing in 'terraform destroy' removes a tailnet device, so a"
  log "ERROR: previously destroyed VM keeps the name and this one is suffixed."
  log "ERROR: Remove the offline '${want}' device, then rebuild. The auto-reap"
  log "ERROR: takes 47-100 minutes, so on a fast rebuild this is expected and"
  log "ERROR: the console is the fix — do not suspect the auth key:"
  log "ERROR:   https://login.tailscale.com/admin/machines"
  write_ts_name_marker "$want" "$got"
  return 1
}

# The durable half of the signal. Content is read by a human and grepped by
# demo-up.sh, so the two field names are a contract; the rest is prose.
#
# Nothing here interpolates the auth key, and nothing here can: this function is
# not passed it and is not in a position to see it.
write_ts_name_marker() {
  local want="$1" got="$2"

  install -d -m 0755 "$(dirname "$TS_NAME_MARKER")" || return 0

  # 0644: the marker is a diagnosis, not a secret, and demo-up.sh reads it as
  # whichever unprivileged account OS Login created.
  cat >"$TS_NAME_MARKER" <<EOF || return 0
requested: ${want}
observed:  ${got}
detected:  $(date --iso-8601=seconds)

This node did not get the MagicDNS name it asked for, so any URL built from
'${want}' points at the wrong node or at nothing.

Cause: 'terraform destroy' removes the GCP instance and does not remove the
tailnet device record. The offline device still owns the name, and this node
was given the next free suffix. The teardown either skipped the explicit
'tailscale logout', or this rebuild happened before the previous node's
auto-reap — measured at 47-100 minutes after disconnect.

Fix: delete the offline '${want}' device at
https://login.tailscale.com/admin/machines and rebuild. The auth key is not the
problem and does not need rotating; a logout removes the record in under 5
seconds, and the same key then reclaims this exact name.
EOF
  chmod 0644 "$TS_NAME_MARKER" 2>/dev/null || true
}

# Releases this node's tailnet device record when the machine shuts down.
#
# ─── This is the BACKSTOP, not the primary mechanism ────────────────────────
#
# The primary removal is demo-up.sh's `ts-logout`, run over SSH before
# `terraform destroy`. That one is primary because it is observable: it runs on
# the operator's terminal, its output is on screen, and a destroy is a
# deliberate act with somebody watching it. This unit covers what that cannot —
# a hard stop, a preemption, an instance deleted from the console, a destroy run
# from somewhere else.
#
# ─── Why the ordering works, which is the whole subtlety ────────────────────
#
# DefaultDependencies is left ON deliberately. It gives this unit the implicit
# `Before=shutdown.target` and `Conflicts=shutdown.target` that make systemd
# stop it as part of every shutdown. Shutdown ordering is the INVERSE of start
# ordering, so the explicit `After=network-online.target tailscaled.service`
# here means the unit is stopped BEFORE tailscaled stops and BEFORE the network
# goes — which is precisely the window in which a logout can still reach the
# coordination server.
#
# Turning DefaultDependencies off, as the obvious hand-written version of this
# unit does, removes the implicit shutdown conflict and the unit is then simply
# never stopped. It would look installed, enabled and correct, and do nothing.
#
# ─── Why every failure is swallowed ─────────────────────────────────────────
#
# `ExecStop=-` prefix: a logout that fails because the tailnet is already
# unreachable, because tailscaled is already down, or because this node was
# never logged in must not hold a shutdown open or mark the boot failed. The
# unit's job is to improve the odds of a clean release, never to have an opinion
# about the shutdown itself. TimeoutStopSec caps the cost of the pathological
# case at 15 seconds.
install_tailscale_logout_unit() {
  # `if ! cat <<HEREDOC ... then`, not `cat <<HEREDOC || { ... }`. The second
  # form puts an unterminated brace group on the same line as the heredoc
  # operator, and where the body ends and the group begins is genuinely
  # ambiguous. This form has no such question.
  if ! cat >"$TS_LOGOUT_UNIT" <<'UNIT'
[Unit]
Description=Release this node's Tailscale device record on shutdown
Documentation=https://tailscale.com/kb/1099/device-approval
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=-/usr/bin/tailscale logout
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
UNIT
  then
    log "WARNING: could not write ${TS_LOGOUT_UNIT}"
    log "WARNING: on a hard kill this node's name is held until the auto-reap,"
    log "WARNING: which is 47-100 minutes. An explicit teardown is unaffected."
    return 0
  fi

  systemctl daemon-reload || {
    log "WARNING: systemctl daemon-reload failed; ${TS_LOGOUT_UNIT_NAME} is not active"
    return 0
  }

  # enable AND start. `enable` alone only arms it for the NEXT boot, and a
  # oneshot with RemainAfterExit has to be STARTED for its ExecStop to run at
  # all — so an enabled-but-never-started unit is the exact shape of a guard
  # that looks installed and has never once fired.
  systemctl enable "$TS_LOGOUT_UNIT_NAME" || {
    log "WARNING: could not enable ${TS_LOGOUT_UNIT_NAME}"
    return 0
  }

  systemctl start "$TS_LOGOUT_UNIT_NAME" || {
    log "WARNING: could not start ${TS_LOGOUT_UNIT_NAME}; its ExecStop will not run"
    return 0
  }

  log "${TS_LOGOUT_UNIT_NAME} installed — this node releases its tailnet name on shutdown"
}

# ---------------------------------------------------------------------------
# Docker socket access for OS Login users
#
# ─── The failure, measured on the running VM ───────────────────────────────
#
#   $ systemctl is-active docker   -> active
#   $ id -nG                       -> sa_102755196918063701885 video
#   $ docker info
#   permission denied while trying to connect to the docker API at
#   unix:///var/run/docker.sock
#
# The daemon is up and healthy; the caller simply cannot open the socket.
# scripts/ci/install-ci-tools.sh then exits 1 with "Docker daemon is not
# running" and scripts/setup.sh with "the docker daemon is not running; start
# it and rerun". BOTH MESSAGES ARE WRONG ABOUT THE CAUSE, and someone will act
# on them and restart a daemon that was never down.
#
# ─── Why the obvious fix is dead code here ─────────────────────────────────
#
# scripts/ci/vm-startup.sh (the v1 CI VM) solves this with
# `usermod -aG docker ci`, and that works there because v1 creates a fixed
# local user. This VM enforces OS Login, so the account is provisioned by the
# guest agent AT FIRST LOGIN — strictly later than this script — and its name
# (sa_<numeric-id> for a service account, <user>_<domain> for a human) is not
# knowable at boot. A `usermod` naming a fixed user here would match nobody,
# succeed silently, and be exactly the correct-looking line that guards nothing.
#
# ─── What was rejected, and why ────────────────────────────────────────────
#
# Widening the socket itself (SocketMode=0666 via a docker.socket drop-in, or a
# world-readable ACL) has no user-name problem and no relogin race, and it was
# still rejected. Docker socket access is ROOT-EQUIVALENT: anyone who can write
# that socket can start a privileged container that mounts the host filesystem.
# 0666 grants that to every local account, including any OS Login principal
# granted plain roles/compute.osLogin without sudo. On an environment whose
# entire demonstration subject is security posture, that is the one change a
# hostile reviewer would open with, and it buys only what the two mechanisms
# below already provide.
#
# ─── What is implemented, in order of preference ───────────────────────────
#
#   1. configure_oslogin_groups — tells the guest agent to place newly
#      provisioned OS Login accounts in `docker`. Applied at ACCOUNT CREATION,
#      which happens before the user's first shell, so there is no relogin
#      race and no permission is widened.
#
#   2. install_docker_group_selfheal — a /etc/profile.d snippet that adds the
#      CURRENT user to `docker` if the guest agent did not. This is the
#      backstop, and its limitation is real and stated out loud below: group
#      membership applies to the NEXT session, so a login that had to fall back
#      to this will see the failure once and succeed on reconnect.
#
# Both are idempotent and neither embeds a username.
# ---------------------------------------------------------------------------

configure_oslogin_groups() {
  local cfg="/etc/default/instance_configs.cfg"

  # The guest agent skips groups that do not exist when the account is
  # provisioned, so docker must already be present. install_docker runs first
  # in main(); this ordering is asserted by test/terraform-vm-profile.bats
  # rather than left to whoever next edits main().
  if ! getent group docker >/dev/null 2>&1; then
    log "WARNING: docker group absent; OS Login users will not receive it"
    return 0
  fi

  if [[ -f "$cfg" ]] && grep -qE '^groups[[:space:]]*=.*\bdocker\b' "$cfg"; then
    log "OS Login supplementary groups already include docker"
    return 0
  fi

  # Written whole rather than edited in place. The file is absent on a stock
  # image, and a sed against a file that may not exist is the kind of edit that
  # reports success having changed nothing.
  cat >"$cfg" <<'CFG'
# Managed by the Signal Loom demo VM startup script.
#
# `groups` places newly provisioned OS Login accounts in these supplementary
# groups. docker is the one that matters: without it, every OS Login user gets
# "permission denied ... /var/run/docker.sock" and the CI tooling misreports it
# as a stopped daemon. The rest are the guest agent's own defaults, restated
# because writing this key replaces the default list rather than adding to it.
[Accounts]
groups = adm,dip,docker,lxd,plugdev,video
CFG

  log "configured OS Login supplementary groups to include docker"
}

install_docker_group_selfheal() {
  # The backstop for the case where the guest agent did not apply the group.
  #
  # Honest about its own limitation: usermod changes the account, not the
  # session that is already running, so the membership takes effect on the NEXT
  # login. A first session that had to fall back to this will still fail to
  # reach the socket. It says so on the terminal rather than leaving the user
  # to discover it, because "permission denied" plus silence is what produced
  # the misdiagnosis in the first place.
  #
  # Runs `sudo -n` only — never prompts. An OS Login principal without sudo
  # gets a message naming the exact command an administrator must run, which is
  # strictly better than a socket error naming nothing.
  cat >/etc/profile.d/99-signalloom-docker-group.sh <<'PROFILE'
# shellcheck shell=sh
# Signal Loom: ensure this OS Login user can reach the Docker socket.
# Installed by the demo VM startup script. Idempotent; safe to source twice.
if command -v docker >/dev/null 2>&1 && ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
  if sudo -n usermod -aG docker "$(id -un)" 2>/dev/null; then
    echo "signalloom: added $(id -un) to the docker group."
    echo "signalloom: group membership applies to your NEXT session — reconnect"
    echo "signalloom: before running the pipeline, or docker will report"
    echo "signalloom: 'permission denied ... /var/run/docker.sock' and the CI"
    echo "signalloom: tooling will misreport it as a stopped daemon."
  else
    echo "signalloom: WARNING - $(id -un) is not in the docker group and this"
    echo "signalloom: session cannot add it. The Docker daemon is running; the"
    echo "signalloom: socket is simply unreachable for you. An administrator"
    echo "signalloom: should run: sudo usermod -aG docker $(id -un)"
  fi
fi
PROFILE
  chmod 0644 /etc/profile.d/99-signalloom-docker-group.sh
  log "installed the docker-group self-heal profile snippet"
}

# Kind's control plane needs more inotify capacity than the Debian default
# allows once several Signal Loom components are running.
tune_kernel_for_kind() {
  log "raising inotify limits for kind"
  cat >/etc/sysctl.d/99-signalloom-kind.conf <<'SYSCTL'
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
SYSCTL
  sysctl --system >/dev/null
}

main() {
  if [[ -f "$MARKER" ]]; then
    log "already bootstrapped, nothing to do"
    return 0
  fi

  [[ "$(id -u)" -eq 0 ]] || die "must run as root"

  install_base_packages

  # Immediately after the base packages, and before the long installs, for one
  # practical reason: everything install_tailscale needs (curl, ca-certificates,
  # apt-transport-https) is already present, and a node that joins the tailnet
  # early is one an operator can watch the REST of this script from. Put it at
  # the end instead and the only view of a bootstrap that fails at minute six is
  # the serial console — which this instance disables.
  #
  # The `|| log` is belt and braces, not the mechanism. Every fallible step
  # inside already handles its own failure; this guarantees that a future edit
  # which forgets to cannot take the whole bootstrap down with it, because the
  # estate does not depend on the tailnet in any way.
  install_tailscale || log "WARNING: the tailscale stage failed; continuing"

  install_docker

  # Both must follow install_docker: the guest agent skips a group that does
  # not exist yet, and the self-heal snippet is pointless without a socket.
  configure_oslogin_groups
  install_docker_group_selfheal

  install_kind
  install_kubectl
  tune_kernel_for_kind

  install -d -m 0755 "$(dirname "$MARKER")"
  date --iso-8601=seconds >"$MARKER"
  log "bootstrap complete"
}

main "$@"
