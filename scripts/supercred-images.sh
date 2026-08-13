#!/usr/bin/env bash
# Build the three SuperCred demo images and put them on the kind node — verified.
#
#   supercred-images.sh build     # build locally only
#   supercred-images.sh load      # build, load onto the node, verify
#   supercred-images.sh verify    # verify only (no build, no load)
#   supercred-images.sh           # same as load
#
# Why this exists rather than a two-line Makefile recipe:
#
# `kind load docker-image` can print "loading..." and exit 0 having transferred
# nothing. The image's manifest lands in containerd's content store while its
# layers do not, so the node ends up with a reference it cannot unpack. kubelet
# then tries to fetch the missing blob from the pull-through mirror, gets an HTML
# error page back, and reports:
#
#   failed to unpack image ... unexpected media type text/html for sha256:… : not found
#
# The trap is that `ctr -n k8s.io images ls` STILL LISTS such an image, because the
# content store holds the manifest. Any check built on `ctr images ls` therefore
# passes while the image is unusable — which is exactly how this failed silently.
# `crictl images` reports the CRI's view (unpacked and runnable), so that is the
# only sound verification and it is what this script uses.
set -euo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"
KIND_BIN="${KIND_BIN:-kind}"
CLUSTER_NAME="${CLUSTER_NAME:-osramp}"
NODE="${SUPERCRED_NODE:-${CLUSTER_NAME}-control-plane}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/source-id.sh
source "${REPO_ROOT}/scripts/lib/source-id.sh"

# image-name|build-context|dockerfile (fields after image-name are repo-root
# relative; dockerfile is optional and defaults to <context>/Dockerfile)
SUPERCRED_IMAGES=(
  "cardvault:local|d2-signalloom/apps/cardvault|"
  "policy-engine:local|d2-signalloom/apps/policy-engine|"
  "cardvault-agent:local|d2-signalloom/apps/cardvault-agent|"
  # Deliberately verify the runner alongside the other SuperCred images. That
  # is stricter than the host-side CLI path alone requires, but omitting it
  # would let the shared preflight pass while the dashboard-driven entrypoint
  # was still undeployed or stale.
  "supercred-demo-runner:local|.|d2-signalloom/apps/supercred-demo-runner/Dockerfile"
)

log()  { printf '\033[1;36m[supercred-images]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[supercred-images] ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[supercred-images] !\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[supercred-images] FAILED:\033[0m %s\n' "$*" >&2; exit 1; }

image_name() {
  local image context dockerfile
  IFS='|' read -r image context dockerfile <<<"$1"
  printf '%s' "$image"
}

image_context() {
  local image context dockerfile
  IFS='|' read -r image context dockerfile <<<"$1"
  printf '%s' "$context"
}

image_dockerfile() {
  local image context dockerfile
  IFS='|' read -r image context dockerfile <<<"$1"
  printf '%s' "$dockerfile"
}

# kind nodes run the host architecture; pin it explicitly so a multi-arch base
# image cannot resolve to a platform the node cannot execute.
host_platform() {
  case "$(uname -m)" in
    x86_64|amd64)  printf 'linux/amd64' ;;
    aarch64|arm64) printf 'linux/arm64' ;;
    *)             printf 'linux/amd64' ;;
  esac
}
PLATFORM="${SUPERCRED_PLATFORM:-$(host_platform)}"

# ─── Verification ───────────────────────────────────────────────────────────

# True when the CRI can actually run the image. Deliberately NOT `ctr images ls`.
#
# The match is done inside a single awk that reads the listing to EOF, rather
# than piping awk into `grep -Fqx`. `grep -q` exits the instant it matches,
# which closes the pipe and kills the upstream `docker exec`/`awk` with SIGPIPE
# (141). Under this script's `set -o pipefail` that 141 becomes the exit status
# of the whole pipeline -- so image_on_node returned FAILURE for an image that
# was present, and returned it *more reliably the more images the node had*,
# because a longer listing loses the race every time. That inverted the entire
# preflight: preflight_images failed closed on a healthy cluster and blocked
# steps 1, 2, 4 and `all` with "images missing", while `crictl images` plainly
# listed all three. awk as the final stage has no early exit, so there is no
# SIGPIPE and its own status is the pipeline's status.
image_on_node() {
  local image="$1"
  local want="docker.io/library/${image%%:*}:${image##*:}"
  "$DOCKER_BIN" exec "$NODE" crictl images 2>/dev/null \
    | awk -v want="$want" '$1":"$2 == want { found = 1 } END { exit !found }'
}

# True when the listing we just read is known to be incomplete, in which case a
# miss proves nothing. The in-cluster shim emits this warning on stderr when
# node.status.images is at the kubelet's --node-status-max-images cap; that
# list is sorted by size, so small images fall off the end while sitting
# perfectly happily on the node.
listing_is_truncated() {
  "$DOCKER_BIN" exec "$NODE" crictl images 2>&1 >/dev/null \
    | grep -q "node.status.images is at the kubelet cap"
}

verify_images() {
  local entry image missing=()
  for entry in "${SUPERCRED_IMAGES[@]}"; do
    image="$(image_name "$entry")"
    if image_on_node "$image"; then
      ok "$image present on $NODE"
    else
      missing+=("$image")
    fi
  done
  if ((${#missing[@]} > 0)); then
    # Do not fail closed on a listing that cannot answer the question.
    #
    # On 2026-08-03 this gate blocked the entire demo with "images are not all
    # present" against a node whose own `crictl images` listed every one of
    # them: the runner's shim reads node.status.images, which was capped at 50
    # and size-sorted, so cardvault:local (8.9MB) and policy-engine:local
    # (14.9MB) were missing from the DATA, not from the node.
    #
    # Being wrong in this direction is expensive and being wrong in the other
    # direction is cheap. A genuinely absent image does not go unnoticed -- the
    # pods run imagePullPolicy: Never, so it surfaces immediately and
    # unmistakably as ErrImageNeverPull on the workload itself, which is a far
    # better error than a preflight guess. So when the listing is known
    # truncated, say so plainly and let the deploy be the judge.
    if listing_is_truncated; then
      warn "not visible in $NODE's image list: ${missing[*]}"
      warn "that list is TRUNCATED (kubelet --node-status-max-images cap), so this"
      warn "is inconclusive rather than missing — continuing. A genuinely absent"
      warn "image will fail loudly as ErrImageNeverPull on the workload."
      return 0
    fi
    warn "missing from $NODE: ${missing[*]}"
    return 1
  fi
  return 0
}

# ─── Build ──────────────────────────────────────────────────────────────────

# Build args that bake a build identity into images which declare the ARGs, so
# scripts/check-deployed-staleness.sh can later read that identity back out of
# the running container and prove the pod is running this source tree.
#
# Empty for images with no marker: passing --build-arg for an ARG a Dockerfile
# never declares is a warning on every build, and noise at build time is how
# real warnings stop being read.
build_id_args() {
  local image="$1" args=()
  mapfile -t args < <(source_id_build_args "${image%%:*}" 2>/dev/null) || return 0
  # Return with NO output when there are no args, rather than falling through to
  # printf. `printf '%s\n'` runs its format once even with zero arguments, so an
  # image with no marker emitted a single blank line here; mapfile in the caller
  # turned that into a one-element array holding "", and docker received an empty
  # positional argument alongside the build context:
  #
  #   docker: 'docker build' requires 1 argument     (it had been handed two)
  #
  # Every SuperCred image failed to build, starting at cardvault:local.
  ((${#args[@]})) || return 0
  printf '%s\n' "${args[@]}"
}

build_images() {
  local entry image context dockerfile id_args
  # TARGETARCH is one of BuildKit's AUTOMATIC build args -- it is populated by
  # the builder, not by the Dockerfile, and the LEGACY builder does not populate
  # it at all. The runner's Dockerfile selects its kubectl checksum on it:
  #
  #   Unsupported TARGETARCH for kubectl:            <- empty, and it exits 1
  #
  # So the build silently depended on the caller having buildx. Docker resolves
  # the buildx plugin through ~/.docker/config.json, and any environment where
  # that file is unreadable falls back to the legacy builder and hits this --
  # a confusing failure four steps into a build, blamed on the Dockerfile.
  # Passing it explicitly costs nothing under BuildKit (same value, stated
  # rather than inferred) and is the difference between working and not without.
  local target_arch="${PLATFORM##*/}"
  for entry in "${SUPERCRED_IMAGES[@]}"; do
    image="$(image_name "$entry")"
    context="$(image_context "$entry")"
    dockerfile="$(image_dockerfile "$entry")"
    mapfile -t id_args < <(build_id_args "$image")
    log "building $image ($PLATFORM)"
    if [ -n "$dockerfile" ]; then
      "$DOCKER_BIN" build --platform "$PLATFORM" --build-arg "TARGETARCH=${target_arch}" ${id_args[@]+"${id_args[@]}"} -f "$REPO_ROOT/$dockerfile" -t "$image" "$REPO_ROOT/$context" \
        || fail "docker build failed for $image via $dockerfile"
    else
      "$DOCKER_BIN" build --platform "$PLATFORM" --build-arg "TARGETARCH=${target_arch}" ${id_args[@]+"${id_args[@]}"} -t "$image" "$REPO_ROOT/$context" \
        || fail "docker build failed for $image"
    fi
  done
  ok "built ${#SUPERCRED_IMAGES[@]} images"
}

# ─── Load ───────────────────────────────────────────────────────────────────

kind_load_all() {
  local entry names=()
  for entry in "${SUPERCRED_IMAGES[@]}"; do names+=("$(image_name "$entry")"); done
  log "loading into kind cluster $CLUSTER_NAME: ${names[*]}"
  # Exit status is not trustworthy here — verification below is what decides.
  "$KIND_BIN" load docker-image --name "$CLUSTER_NAME" "${names[@]}" || true
}

# Rebuild straight into a docker-archive tarball and import that.
#
# This is the recovery path for an image `kind load` silently declines to
# transfer. It never round-trips through the local docker image store, so a
# layer that was only lazily materialised there cannot be the missing blob:
# `--output type=docker,dest=…` forces BuildKit to write every layer into the
# archive before the command returns.
reload_via_archive() {
  local image="$1" context="$2" dockerfile="${3:-}"
  local tar
  tar="$(mktemp -t "supercred-${image%%:*}-XXXXXX.tar")"
  # shellcheck disable=SC2064  # expand $tar now, not at trap time
  trap "rm -f '$tar'" RETURN

  log "recovery: rebuilding $image directly into an archive"
  if [ -n "$dockerfile" ]; then
    "$DOCKER_BIN" buildx build \
      --platform "$PLATFORM" \
      --provenance=false --sbom=false \
      --output "type=docker,dest=$tar" \
      -f "$REPO_ROOT/$dockerfile" \
      -t "$image" "$REPO_ROOT/$context" \
      || { warn "buildx archive build failed for $image via $dockerfile"; return 1; }
  else
    "$DOCKER_BIN" buildx build \
      --platform "$PLATFORM" \
      --provenance=false --sbom=false \
      --output "type=docker,dest=$tar" \
      -t "$image" "$REPO_ROOT/$context" \
      || { warn "buildx archive build failed for $image"; return 1; }
  fi

  log "recovery: importing $image into containerd on $NODE"
  # `kind load` can leave the requested tag pointing at an incomplete HTML
  # manifest. Importing under that occupied reference reports success but keeps
  # the poisoned target, so CRI cannot adopt the recovered archive. Remove only
  # the known-unrunnable reference immediately before its replacement.
  "$DOCKER_BIN" exec "$NODE" \
    ctr -n k8s.io images rm "docker.io/library/${image%%:*}:${image##*:}" >/dev/null 2>&1 \
    || true
  # --snapshotter=overlayfs so the layers are unpacked into the snapshotter the
  # CRI actually reads. Without it the import succeeds and the image is not
  # runnable.
  "$DOCKER_BIN" exec -i "$NODE" \
    ctr -n k8s.io images import --all-platforms --snapshotter=overlayfs - <"$tar" \
    || { warn "ctr import failed for $image"; return 1; }

  # Load-bearing, and the reason this recovery path had never once worked.
  #
  # containerd's CRI plugin only surfaces images carrying this label. An
  # imported-but-unlabelled image sits in the content store, is listed by
  # `ctr images ls`, is NOT listed by `crictl images`, and cannot be run — so
  # the recovery reported success, the verification that follows it failed, and
  # the whole thing read as "the archive rebuild didn't help either".
  #
  # Observed on the CI VM 2026-08-04: after recovery, `ctr images ls` listed
  # cardvault-agent:local while `crictl images` did not, and the deploy failed.
  # Adding the label made crictl list it immediately.
  "$DOCKER_BIN" exec "$NODE" \
    ctr -n k8s.io images label "docker.io/library/${image%%:*}:${image##*:}" \
      io.cri-containerd.image=managed >/dev/null \
    || { warn "could not label $image as CRI-managed"; return 1; }

  # The CRI does not adopt the freshly-labelled image synchronously, so an
  # immediate re-verify can miss it by a second or two. Observed on the CI VM
  # 2026-08-04: recovery labelled cardvault-agent:local, the caller's
  # verification reported it missing and failed the build, and `crictl images`
  # listed it moments later. A recovery that worked and was then declared a
  # failure is worse than one that plainly did not work, because it sends the
  # reader looking in the wrong place.
  # 90s, not 20s. The 20 was fitted to cardvault-agent (54MB) on 2026-08-04 and
  # is not a property of containerd — adoption follows the snapshotter unpacking
  # the layers, so it scales with image size. supercred-demo-runner is 111MB,
  # roughly twice that, and on 2026-08-13 it timed out at 20s having worked:
  # `crictl images` listed it a short time later and the pod ran from it with no
  # further intervention.
  #
  # That is precisely the failure the comment above warns about, reproduced by
  # the fix for it — the recovery succeeded and was declared a failure, and the
  # reader was sent to look at the registry (the bare `:local` tag resolves to
  # docker.io, so the kubelet's message names Docker Hub) instead of at a wait
  # that was simply too short.
  local waited=0
  while [ "$waited" -lt "${SUPERCRED_CRI_ADOPT_TIMEOUT:-90}" ]; do
    image_on_node "$image" && return 0
    sleep 1
    waited=$((waited + 1))
  done

  # Say which of the two states we are actually in. "Not adopted" with the image
  # sitting in the content store is a slow unpack and is very likely to resolve
  # on its own; "not adopted" with nothing in the content store is a genuinely
  # failed import. Collapsing those into one message is what made this cost an
  # afternoon.
  if "$DOCKER_BIN" exec "$NODE" ctr -n k8s.io images ls -q 2>/dev/null \
      | grep -Fqx "docker.io/library/${image%%:*}:${image##*:}"; then
    warn "$image is in the content store and labelled, but the CRI has not adopted it after ${waited}s — this is a slow unpack, not a failed import; re-run and it will usually be present"
  else
    warn "$image is not in the content store after ${waited}s — the import itself failed"
  fi
  return 1
}

load_images() {
  kind_load_all

  local entry image context dockerfile recovered=0
  for entry in "${SUPERCRED_IMAGES[@]}"; do
    image="$(image_name "$entry")"
    context="$(image_context "$entry")"
    dockerfile="$(image_dockerfile "$entry")"
    if image_on_node "$image"; then
      continue
    fi
    warn "$image did not reach $NODE via kind load — attempting recovery"
    reload_via_archive "$image" "$context" "$dockerfile" || true
    recovered=1
  done
  [ "$recovered" -eq 1 ] && log "recovery attempted; re-verifying"

  if ! verify_images; then
    fail "one or more SuperCred images are not runnable on $NODE.
       'ctr images ls' can list an image whose layers never transferred, so this
       check uses 'crictl images' instead — a listed-but-unusable image is
       reported as missing here on purpose.
       Inspect with:
         docker exec $NODE crictl images
         docker exec $NODE ctr -n k8s.io images ls
       Then retry:  make demo-signalloom-supercred-images"
  fi
  ok "all SuperCred images verified runnable on $NODE"

  # `supercred-demo-runner` uses imagePullPolicy: IfNotPresent. Loading a new
  # local tag does not replace an already-running pod, so dashboard-triggered
  # steps could execute an older runner than the CLI path just verified.
  if kubectl -n fe-signalloom get deployment supercred-demo-runner >/dev/null 2>&1; then
    kubectl -n fe-signalloom rollout restart deployment/supercred-demo-runner
    kubectl -n fe-signalloom rollout status deployment/supercred-demo-runner --timeout=300s
  fi
}

# ─── Dispatch ───────────────────────────────────────────────────────────────

case "${1:-load}" in
  build)  build_images ;;
  load)   build_images; load_images ;;
  verify) verify_images || fail "SuperCred images are not all present on $NODE — run: make demo-signalloom-supercred-images" ;;
  *)
    echo "Usage: $0 {build|load|verify}" >&2
    exit 1
    ;;
esac
