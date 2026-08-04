#!/usr/bin/env bats
#
# The kind config heredoc is UNQUOTED, so its contents are live shell.
#
# create-kind-cluster.sh writes the kind config with `cat >"$kind_config" <<EOF`
# — deliberately unquoted, because it has to expand the cluster name and the zot
# cache path. That makes backticks, dollar-parens and bare dollar-names active
# inside the heredoc, INCLUDING inside YAML comments, which read as inert prose
# and are not.
#
# This bit twice inside a single edit on 2026-08-03:
#
#   1. A comment referred to a tool name in backticks. Bash ran it. The cluster
#      creation aborted with "crictl: command not found", the image build never
#      happened, no ResourceSets were created, and BOTH CI VMs failed before
#      reaching a single test stage — reported as "aborted run, NOT a test
#      failure", which was accurate and gave no hint where to look.
#
#   2. The comment WARNING about (1) used dollar-parens as its example, which
#      were duly substituted away, and named two shell variables, which were
#      expanded into the prose.
#
# Neither produced a syntax error. `bash -n` passes on both. The only symptom is
# a config file with holes in it and a command run that nobody asked for — so
# this is checked mechanically rather than by review.

setup() {
  root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  script="$root/scripts/create-kind-cluster.sh"
}

# The heredoc body, from the `cat >` line to its terminator.
heredoc_body() {
  awk '/^cat >"\$kind_config" <<EOF$/{f=1;next} f&&/^EOF$/{f=0} f' "$script"
}

@test "KINDCFG the heredoc is present and unquoted (the premise of this file)" {
  # If it ever becomes <<'EOF', these checks are unnecessary — but so is the
  # variable expansion the script depends on, so that would be a real change
  # and should fail here rather than pass silently.
  run grep -F 'cat >"$kind_config" <<EOF' "$script"
  [ "$status" -eq 0 ]
}

@test "KINDCFG no backticks anywhere in the heredoc" {
  body="$(heredoc_body)"
  if printf '%s' "$body" | grep -q '`'; then
    echo "Backticks inside an unquoted heredoc are command substitution."
    printf '%s\n' "$body" | grep -n '`'
    return 1
  fi
}

@test "KINDCFG no command substitution in the heredoc" {
  body="$(heredoc_body)"
  if printf '%s' "$body" | grep -qF '$('; then
    echo "Dollar-parens inside an unquoted heredoc execute."
    printf '%s\n' "$body" | grep -nF '$('
    return 1
  fi
}

@test "KINDCFG only the two intended variables are expanded" {
  # Any other dollar-name is either a typo or prose that will be silently
  # replaced with an empty string in the generated config.
  body="$(heredoc_body)"
  local stray
  stray="$(printf '%s' "$body" \
    | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' \
    | grep -vE '^\$\{?(CLUSTER_NAME|ZOT_CACHE_DIR)\}?$' \
    | sort -u || true)"
  if [ -n "$stray" ]; then
    echo "Unexpected shell variables inside the kind config heredoc:"
    printf '  %s\n' $stray
    echo "They expand to empty and leave holes in the generated YAML."
    return 1
  fi
}

@test "KINDCFG the rendered config is valid YAML with the kubelet patch intact" {
  # The end-to-end check: render it exactly as the script does and parse it.
  # A substitution hole usually still parses, so also assert the setting that
  # motivated the patch actually survived.
  local out
  out="$(CLUSTER_NAME=testcluster ZOT_CACHE_DIR=/tmp/zot-test bash -c '
    kind_config=/dev/stdout
    '"$(awk '/^cat >"\$kind_config" <<EOF$/,/^EOF$/' "$script")"'
  ')"
  printf '%s' "$out" | python3 -c 'import sys,yaml; yaml.safe_load(sys.stdin.read())'
  printf '%s' "$out" | grep -qF 'nodeStatusMaxImages: 0'
  printf '%s' "$out" | grep -qF 'name: testcluster'
  printf '%s' "$out" | grep -qF '/tmp/zot-test'
}
