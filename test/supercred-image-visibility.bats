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
fake_kubectl() { # count
  local count="$1" dir
  dir="$(mktemp -d)"
  cat > "$dir/kubectl" <<EOF
#!/usr/bin/env bash
python3 -c '
import json, sys
n = int(sys.argv[1])
imgs = [{"names": ["docker.io/library/img%d:local" % i], "sizeBytes": 1000 + i} for i in range(n)]
if n >= 3:
    imgs[2]["names"] = None          # the digest-only entry that used to crash it
print(json.dumps({"status": {"images": imgs}}))
' "$count"
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

@test "IMGVIS verify_images refuses to fail closed on a truncated listing" {
  run grep -F 'listing_is_truncated' "$images"
  [ "$status" -eq 0 ]
  # The truncated branch must return success, not just warn and fall through.
  awk '/^verify_images\(\)/,/^}/' "$images" | grep -A6 'if listing_is_truncated' | grep -q 'return 0'
}

@test "IMGVIS verify_images still fails when the listing is complete" {
  # The permissive branch must be reachable ONLY via listing_is_truncated.
  # Otherwise the gate stops gating anything at all.
  body="$(awk '/^verify_images\(\)/,/^}/' "$images")"
  echo "$body" | grep -q 'warn "missing from \$NODE'
  echo "$body" | grep -qE 'return 1'
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
