#!/usr/bin/env bats
#
# A truncated image listing must not be read as "the image is missing".
#
# node.status.images is CAPPED and SORTED BY SIZE. The kubelet's
# --node-status-max-images defaults to 50 and it reports the fifty LARGEST
# images, so on a node holding more than that, small images are simply not in
# the object. The in-cluster demo runner has no crictl and no docker socket, so
# its shim derives the image list from exactly that object — which means the
# preflight was asking a question its data source could not answer.
#
# Observed 2026-08-03 on a completely healthy kind node: `crictl images` on the
# node listed all four SuperCred images; node.status.images held exactly 50
# entries and omitted cardvault:local (8.9MB) and policy-engine:local (14.9MB)
# purely for being too small to rank. The preflight blocked the whole demo with
# "SuperCred images are not all present".
#
# Three defences, one per layer, because each fails differently:
#   1. the cluster reports every image      (create-kind-cluster.sh, root cause)
#   2. the shim declares when it is truncated (supercred-crictl-shim.sh)
#   3. the gate refuses to fail closed on truncated data (supercred-images.sh)
#
# Layer 1 only helps clusters created after this change, which is exactly why
# layers 2 and 3 exist.

setup() {
  root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  shim="$root/scripts/supercred-crictl-shim.sh"
  images="$root/scripts/supercred-images.sh"
  kindcfg="$root/scripts/create-kind-cluster.sh"
}

# Build a fake `kubectl` whose `get node -o json` returns a node object with a
# controllable number of images, so the shim can be driven without a cluster.
#
# Trailing arguments are extra image references to include verbatim, which is
# how a test stages "the node really does hold cardvault:local". They are
# counted towards $count, so `fake_kubectl 50 …` still sits exactly on the
# kubelet cap and still triggers the truncation warning.
#
# `get pods` returns an empty list: the shim's started-container evidence is a
# second, conclusive source, and letting it answer here would mask whether the
# node-listing path behaves correctly on its own.
fake_kubectl() { # count [extra-image-ref...]
  local count="$1" dir; shift
  dir="$(mktemp -d)"
  cat > "$dir/kubectl" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "get" ] && [ "\$2" = "pods" ]; then
  echo '{"items": []}'
  exit 0
fi
python3 -c '
import json, sys
n = int(sys.argv[1])
extra = sys.argv[2:]
imgs = [{"names": [ref], "sizeBytes": 9_000_000} for ref in extra]
for i in range(n - len(extra)):
    imgs.append({"names": ["docker.io/library/img%d:local" % i], "sizeBytes": 1000 + i})
if len(imgs) > 2 and not extra:
    imgs[2]["names"] = None          # the digest-only entry that used to crash it
print(json.dumps({"status": {"images": imgs}}))
' "$count" $(printf '%q ' "$@")
EOF
  chmod +x "$dir/kubectl"
  echo "$dir"
}

@test "IMGVIS the shim survives a null names entry and lists everything after it" {
  # The original crash: it printed the first two rows, hit the null, raised
  # TypeError and exited — so every image after index 2 was invisible.
  dir="$(fake_kubectl 10)"
  run env KUBECTL_BIN="$dir/kubectl" bash "$shim" exec somenode crictl images
  [ "$status" -eq 0 ]
  # 10 images, one nulled, one header line => 9 data rows.
  [ "$(echo "$output" | grep -c 'docker.io/library/img')" -eq 9 ]
  rm -rf "$dir"
}

@test "IMGVIS the shim warns when the listing is at the kubelet cap" {
  dir="$(fake_kubectl 50)"
  run env KUBECTL_BIN="$dir/kubectl" bash "$shim" exec somenode crictl images
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "node.status.images is at the kubelet cap"
  rm -rf "$dir"
}

@test "IMGVIS the shim does NOT warn on a listing below the cap" {
  # A false truncation warning would make the gate permanently permissive,
  # which is the opposite failure and just as bad.
  dir="$(fake_kubectl 10)"
  run env KUBECTL_BIN="$dir/kubectl" bash "$shim" exec somenode crictl images
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "kubelet cap"
  rm -rf "$dir"
}

@test "IMGVIS the truncation warning goes to stderr, leaving the table parseable" {
  # supercred-images.sh parses stdout with awk on \$1\":\"\$2. A warning on
  # stdout would become a row and could match nothing or, worse, something.
  dir="$(fake_kubectl 50)"
  run env KUBECTL_BIN="$dir/kubectl" bash -c "bash '$shim' exec somenode crictl images 2>/dev/null"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "kubelet cap"
  echo "$output" | head -1 | grep -q "^IMAGE TAG IMAGE ID SIZE$"
  rm -rf "$dir"
}

# ─── Layer 3, exercised rather than grepped ─────────────────────────────────
#
# These three used to be two tests that grepped verify_images' source for
# `return 0` and `warn "missing from $NODE`. That pinned an implementation, not
# a behaviour: it could not tell a gate that answers correctly from one that
# merely still contains the right string, and it went red the moment the
# function was restructured — while saying nothing about whether the
# restructuring was correct.
#
# So they run the REAL shim against the REAL gate now, with only kubectl faked.
# That also exercises the join between them, which is where the 2026-08-03
# failure actually lived.

# Drive supercred-images.sh with the real shim standing in for docker.
run_gate() { # subcommand node-image-count [extra image names...]
  local sub="$1" count="$2"; shift 2
  local dir; dir="$(fake_kubectl "$count" "$@")"
  # DOCKER_BIN is the shim itself: the exact substitution the runner pod makes,
  # where /usr/local/bin/docker IS scripts/supercred-crictl-shim.sh.
  run env KUBECTL_BIN="$dir/kubectl" DOCKER_BIN="$shim" SUPERCRED_NODE=somenode \
    bash "$images" "$sub"
  rm -rf "$dir"
}

@test "IMGVIS the gate refuses to FAIL CLOSED on a truncated listing" {
  # 2026-08-03: absent from a capped, size-sorted list is not absent from the
  # node, and treating it as such blocked the entire demo against a healthy
  # cluster. Exit 1 here is the regression.
  run_gate verify 50
  [ "$status" -ne 1 ]
}

@test "IMGVIS the gate refuses to PASS on a truncated listing either" {
  # …and the obvious correction is the other defect. A gate that cannot see
  # must not claim it looked: on 2026-08-17 a check that could not distinguish
  # a fresh image from a stale one assumed fresh and shipped stale.
  #
  # Exit 3 is COULD-NOT-VERIFY. Neither 0 nor 1 is an honest answer here.
  run_gate verify 50
  [ "$status" -eq 3 ]
  echo "$output" | grep -q "COULD-NOT-VERIFY"
}

@test "IMGVIS the gate still FAILS when a complete listing omits the images" {
  # The control. Without it, "truncated means inconclusive" could be
  # implemented as "absence always means inconclusive" and the gate would have
  # stopped gating anything at all — which is precisely what the deleted
  # source-grep test was reaching for, and could not actually check.
  run_gate verify 10
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "FAIL on somenode"
}

@test "IMGVIS the gate PASSES on presence when a complete listing has them all" {
  # The fourth corner, so the three above cannot be satisfied by a gate that
  # simply never passes.
  # Fully qualified, because that is how the kubelet records them in
  # node.status.images and how crictl prints them.
  run_gate verify 10 \
    docker.io/library/cardvault:local docker.io/library/policy-engine:local \
    docker.io/library/cardvault-agent:local docker.io/library/supercred-demo-runner:local
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "presence only — identity not checked"
}

@test "IMGVIS the shim's empty ID column cannot masquerade as an identity match" {
  # The shim reads the API server and has no image ID to report, so it prints
  # `-`. An implementation that normalised that to "" and compared it against a
  # local "" would report a perfect match for two things it never looked at.
  # Same vacuous-pass bug class, re-entering through its own fix.
  #
  # Every image IS present here, so presence passes (test above) — and identity
  # must still refuse to.
  run_gate verify-identity 10 \
    docker.io/library/cardvault:local docker.io/library/policy-engine:local \
    docker.io/library/cardvault-agent:local docker.io/library/supercred-demo-runner:local
  [ "$status" -eq 3 ]
  echo "$output" | grep -q "COULD-NOT-VERIFY"
}

@test "IMGVIS the kind cluster is configured to report every image" {
  # Root-cause layer. kubelet uses -1 for an unlimited image list.
  run grep -F 'nodeStatusMaxImages: -1' "$kindcfg"
  [ "$status" -eq 0 ]
  run grep -F 'kind: KubeletConfiguration' "$kindcfg"
  [ "$status" -eq 0 ]
}

@test "IMGVIS the shim still fails closed on an argv it does not understand" {
  # Pre-existing guarantee that must survive this change: a shim exiting 0 for
  # an unhandled command turns the whole verify step into a gate that passes.
  #
  # `[ "$status" -ne 0 ]` alone did not test that. `bash "$shim"` on a missing
  # or unreadable file exits 127/126, and a moved shim would have satisfied this
  # test forever while proving nothing about fail-closed behaviour. Assert the
  # subject exists, then assert the SPECIFIC refusal the shim implements.
  [ -f "$shim" ]

  run bash "$shim" images --format '{{.Repository}}'
  # unsupported() exits 1 after naming the argv on stderr. 127 (not found) and
  # 126 (not executable) are different findings and must not read as a pass.
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsupported docker argv"* ]]
}
